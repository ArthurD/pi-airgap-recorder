# Storage costs and strategy

Running log of where the archive's bytes live, what they cost, and what we
decided about it. Append a dated section per review; keep the older ones so
the growth curve and the decisions stay visible. Numbers are decimal TB for
S3 (what AWS bills) and TiB for the NAS (what `df` prints). Bucket names,
hostnames, and folder names that identify people stay out of this file; they
live in `tools/umik.local.conf`, which is untracked.

Standing answers, so the next review starts from them:

- The archive is three copies: S3 is the immutable truth (Object Lock,
  write-once uploader), the NAS is the quick-access copy, the SSD is scratch.
- S3 storage class has no effect on the integrity story. Object Lock does not
  block storage-class transitions, and `umik verify-s3` uses HeadObject, which
  works on archived objects.
- Egress is the only real S3 cost trap: pulling the whole archive home costs
  about $90 per TB regardless of class. A future bulk-analysis pass should run
  in-region, not at home.
- Growth is set by two knobs: how long the mics run (`umik scrap` for sticks
  with nothing worth keeping) and the recording format (float at 192 kHz is
  2.76 GB per hour; 24-bit at 48 kHz would be about a tenth of that).

## 2026-10-23 review

Asked because the NAS was filling up and S3 looked set to follow. Conclusion:
not cost-prohibitive, and not close. One decision matters, and it is still
pending: a lifecycle transition on the UMIK bucket.

### Where the bytes are

| Place | Size | Notes |
|---|---|---|
| S3, UMIK bucket | 1.44 TB, 11,940 objects | 100% Standard, no lifecycle tiering, 1 noncurrent version |
| S3, camera-export bucket | 5.60 TB, 22,617 objects | 99.8% Deep Archive, 10 GB Standard, Object Lock compliance to 2029-08 |
| NAS volume | 25.4 of 29.7 TiB used | 4.3 TiB free, 86% |
| NAS, our share in total | ~7.9 TiB | all 32 top-level folders measured |
| NAS, camera NVR backup | 4.43 TiB | largest single folder |
| NAS, Umik Recordings | 1.28 TiB | about 5% of the volume |
| NAS, phone/laptop/photo backups | ~1.6 TiB combined | six folders, 0.1 to 0.55 TiB each |
| NAS, everything else | under 0.2 TiB each | |

The NAS finding: our share holds about 8 TiB but the volume shows 25 TiB
used, so roughly 17.5 TiB sits in other shared folders, snapshots, backup
packages, or recycle bins that the guest SMB mount cannot see. Check DSM
Storage Manager before blaming UMIK. At the October pace the free space is
about 4.5 months of UMIK growth if nothing else grows.

### Growth

UMIK bucket by recording month: Aug 188 GB, Sep 394 GB, Oct 713 GB through
the 21st. Call it 1 TB per month. unit 1 (RODE, float at 192 kHz) was 606 of
October's 713 GB.

### Prices used

List prices, us-east-1, October 2026, per GB-month: Standard $0.023, Glacier
Instant Retrieval $0.004, Glacier Flexible Retrieval $0.0036, Deep Archive
$0.00099. Egress $0.09 per GB. Deep Archive bulk restore $0.0025 per GB with
a 48-hour wait; Glacier Instant retrieval $0.03 per GB. Per-object overheads
(metadata, minimum sizes, minimum storage durations) are negligible at 100 MB
segments. Sources, which agree with each other and with AWS's own page:

- https://filebase.com/blog/aws-s3-pricing-in-2026-what-youll-actually-pay/
- https://upstash.com/blog/aws-s3-pricing-explained-2026
- https://www.cloudforecast.io/amazon-s3-pricing-and-optimization-guide/
- https://cloudburn.io/blog/amazon-s3-pricing

### Five-year projection, UMIK bucket

Starting from 1.44 TB, growing 1 TB per month, cost per year:

| Year | Standard | Glacier Instant | Deep Archive |
|---|---|---|---|
| 1 | $2,200 | $380 | $95 |
| 2 | $5,500 | $960 | $240 |
| 3 | $8,800 | $1,530 | $380 |
| 4 | $12,100 | $2,110 | $520 |
| 5 | $15,400 | $2,690 | $665 |
| 5-year total | $44,000 | $7,700 | $1,900 |

Sensitivity: at 0.75 TB per month, Standard $33.6k vs Deep Archive $1.4k
over five years; at 1.5 TB per month, $65k vs $2.8k. By year 5 the bucket
holds about 61 TB, which is $1,400 a month at Standard or $61 at Deep
Archive.

Camera-export bucket: flat, about $67 a year in Deep Archive; about $245 a
year if the remaining 15 TB of NVR footage is ever exported to it.

Run-rate at review time: about $39 a month in total, $33 of it the UMIK
bucket sitting in Standard.

### Recommendation

Add a lifecycle rule to the UMIK bucket that transitions objects after 0 or
30 days:

- **Deep Archive** if the NAS stays the analysis copy and S3 is the
  backstop. Cheapest by far; a restore is a 12 to 48 hour wait.
- **Glacier Instant Retrieval** if S3 itself must be readable immediately for
  a future bulk-AI pass. 4x Deep Archive, still 6x cheaper than Standard.

Either way the change needs the admin profile (the uploader cannot touch
bucket configuration, by design). Not yet done; see Decisions.

### Not measured this time

The admin AWS session had expired, so these are still unread: the bucket's
lifecycle rules and Object Lock configuration, CloudWatch bucket-size
metrics, and the actual Cost Explorer bills. Everything above comes from
object listings and list prices.

### Decisions

- 2026-10-23: review done, lifecycle tiering recommended, **not applied**.
  Owner's call between Deep Archive and Glacier Instant Retrieval.

## How to redo the measurement

Object counts, sizes, and storage classes straight from the bucket (read-only
calls, fine with the uploader profile):

```sh
aws s3api list-objects-v2 --bucket "$UMIK_S3_BUCKET" --profile umik \
  --query 'Contents[].{k:Key,s:Size,c:StorageClass,m:LastModified}' \
  --output json > s3-objects.json
python3 -c '
import json,collections
o=json.load(open("s3-objects.json"))
by=collections.Counter(); cls=collections.Counter()
for x in o:
    by[x["k"].split("/")[1][:7] if x["k"].startswith("raw/") else "other"]+=x["s"]
    cls[x["c"]]+=x["s"]
print(len(o),"objects",sum(x["s"] for x in o)/1e12,"TB")
for k,v in sorted(by.items()): print(k, round(v/1e9), "GB")
for k,v in cls.items(): print(k, round(v/1e9), "GB")'
aws s3api list-object-versions --bucket "$UMIK_S3_BUCKET" --profile umik \
  --query '{nc: length(Versions[?IsLatest==`false`]), dm: length(DeleteMarkers)}'
```

Bucket configuration and bills need the admin profile (`aws login --profile
admin` first):

```sh
aws s3api get-bucket-lifecycle-configuration --bucket "$UMIK_S3_BUCKET" --profile admin
aws s3api get-object-lock-configuration        --bucket "$UMIK_S3_BUCKET" --profile admin
aws ce get-cost-and-usage --profile admin --granularity MONTHLY --metrics UnblendedCost \
  --time-period Start=$(date -v-6m +%Y-%m-01),End=$(date +%Y-%m-01) \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Simple Storage Service"]}}'
```

NAS: `df -h` on the mount for the volume, then `du -sk` per top-level folder
of the share (slow over SMB; background it and append per folder). Remember
the share is not the volume; the difference is what DSM has to explain.
