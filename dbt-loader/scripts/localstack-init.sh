#!/bin/sh
# Runs inside localstack once it is ready (mounted into /etc/localstack/init/ready.d/).
# The integration tests assume the bucket already exists (they never call create_bucket).
awslocal s3 mb s3://continuo
