# Enable CloudTrail (all regions, log to S3)
aws cloudtrail create-trail \
  --name tch-audit-trail \
  --s3-bucket-name tch-cloudtrail-logs \
  --is-multi-region-trail \
  --enable-log-file-validation \
  --include-global-service-events

aws cloudtrail start-logging --name tch-audit-trail
