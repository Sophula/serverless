# Create an S3 bucket for backups
resource "aws_s3_bucket" "backup_bucket" {
  bucket = "rds-university-backup-bucket-23"
  acl    = "private"
}

# Create an IAM role for the RDS instance
resource "aws_iam_role" "rds_role" {
  name = "rds-backup-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "rds.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Attach a policy to the IAM role
resource "aws_iam_role_policy_attachment" "rds_policy_attachment" {
  role       = aws_iam_role.rds_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# Create a DB snapshot to backup
resource "aws_db_snapshot" "rds_snapshot" {
  db_instance_identifier = aws_db_instance.university.identifier
  db_snapshot_identifier = "rds-university-snapshot"
}

/*
# Move the DB snapshot to S3 Glacier
resource "aws_glacier_vault" "glacier_vault" {
  name = "rds-university-backup-glacier-vault"
}

resource "aws_glacier_vault_lock" "glacier_vault_lock" {
  vault_name    = aws_glacier_vault.glacier_vault.name
  complete_lock = true
  policy        = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Principal": "*",
      "Action": "glacier:DeleteArchive"
    }
  ]
}
EOF

  # Associate the DB snapshot with the Glacier vault
  provisioner "local-exec" {
    command = "aws glacier upload-archive --vault-name ${aws_glacier_vault.glacier_vault.name} --body ${aws_db_snapshot.rds_snapshot.id}"
  }
}
*/
