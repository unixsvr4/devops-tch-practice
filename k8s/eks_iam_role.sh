# Create IAM role for a service account (e.g., app needing S3)
eksctl create iamserviceaccount \
  --name app-sa \
  --namespace payment-app \
  --cluster tch-prod \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
