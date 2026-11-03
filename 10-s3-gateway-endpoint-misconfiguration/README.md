# Lab 10 — S3 Gateway Endpoint Misconfiguration

## Overview

This lab demonstrates how to troubleshoot an Amazon S3 Gateway VPC Endpoint connectivity failure caused by an incorrect route table association.

A private Amazon EC2 instance needs to download objects from Amazon S3 without using an Internet Gateway or NAT Gateway.

Initially, the EC2 instance can access S3 through a gateway endpoint. We intentionally remove the endpoint's association with the private subnet's route table, causing the S3 prefix-list route to disappear.

The endpoint remains available, but S3 downloads fail because there is no valid network route to the service.

We investigate the failure, identify the missing route table association, restore it, verify S3 connectivity, and clean up all temporary resources.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce Failure → Investigate → Identify Root Cause → Remediate → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-010 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, S3, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, Linux |
| VPC CIDR | `10.100.0.0/16` |
| Private Subnet | `10.100.1.0/24` |
| Public IPv4 | None |
| S3 Endpoint Type | Gateway |
| S3 Endpoint Service | `com.amazonaws.us-east-1.s3` |
| S3 Route Destination | AWS-managed S3 prefix list |
| Simulated Failure | Endpoint route table association removed |
| Root Cause | Missing S3 prefix-list route |
| Remediation | Restore the endpoint route table association |
| Verification | Successful S3 object download |
| Internet Gateway | None |
| NAT Gateway | None |

---

## 2. Production Incident Scenario

### Incident Description

A company operates applications inside private AWS subnets.

The applications regularly download configuration files, software packages, and other objects from Amazon S3.

To avoid public internet access, the company uses an S3 Gateway VPC Endpoint.

Following a network configuration change, an application can no longer download an S3 object.

The cloud engineer investigates and discovers:

- The EC2 instance is running.
- The instance has no public IPv4 address.
- The S3 bucket and requested object exist.
- The IAM role grants the required `s3:GetObject` permission.
- DNS resolution works.
- The S3 Gateway Endpoint exists and is available.
- The private route table is no longer associated with the S3 endpoint.
- The S3 prefix-list route has disappeared.
- No NAT Gateway or Internet Gateway provides an alternative path.

### Expected Behavior

```text
Private EC2
    |
    v
Private Route Table
    |
    | S3 Prefix List → Gateway Endpoint
    v
S3 Gateway Endpoint
    |
    v
Amazon S3
    |
    v
Object Download Successful
```

### Failure Behavior

```text
Private EC2
    |
    v
Private Route Table
    |
    X
S3 Endpoint Association Missing
    |
    X
No Route to S3
    |
    X
Object Download Fails
```

### Potential Business Impact

- Applications cannot retrieve S3 objects.
- Configuration downloads fail.
- Backup or restore workflows may stop.
- Data-processing pipelines become unavailable.
- Application deployments may fail.
- Production workloads lose access to required dependencies.

### Incident Objective

Identify why S3 connectivity fails despite valid IAM permissions and an available gateway endpoint, then restore the correct private network path.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                    AWS Region: us-east-1

             +-----------------------------------+
             | AWS VPC                           |
             | 10.100.0.0/16                     |
             |                                   |
             | Private Subnet                    |
             | 10.100.1.0/24                     |
             |                                   |
             |      Private EC2                  |
             |      No Public IPv4               |
             |      IAM Role                     |
             |          |                        |
             |          v                        |
             |      Route Table                  |
             |      10.100.0.0/16 → local        |
             |      S3 Prefix List → Endpoint    |
             |          |                        |
             |          v                        |
             |      S3 Gateway Endpoint          |
             |          |                        |
             +----------|------------------------+
                        |
                        v
                    Amazon S3
```

### Broken Architecture

```text
Private EC2
    |
    v
Private Route Table
    |
    | Only Local VPC Route
    |
    X
S3 Prefix-List Route Missing
    |
    X
Cannot Reach S3
```

### AWS Resources

| Resource | Purpose |
|---|---|
| Dedicated VPC | Isolates the lab |
| Private subnet | Hosts the EC2 instance |
| Private route table | Controls S3 traffic routing |
| S3 Gateway Endpoint | Provides private access to S3 |
| S3 bucket | Stores the test object |
| IAM role | Grants permission to retrieve the test object |
| SSM interface endpoint | Provides private Systems Manager API access |
| SSM Messages endpoint | Supports Session Manager |
| Security groups | Control EC2 and interface endpoint traffic |

The SSM interface endpoints remain independent of the S3 Gateway Endpoint, allowing the engineer to troubleshoot the S3 failure through Session Manager.

---

## 4. Understanding S3 Gateway Endpoints

An S3 Gateway VPC Endpoint allows supported resources inside a VPC to reach Amazon S3 without using a NAT Gateway or Internet Gateway.

Gateway endpoints use route table entries rather than endpoint network interfaces.

### Important Characteristics

1. Gateway endpoints support Amazon S3 and DynamoDB.
2. They use AWS-managed service prefix lists.
3. They must be associated with the appropriate route tables.
4. AWS automatically manages their gateway endpoint routes.
5. They do not have endpoint security groups.
6. They support endpoint policies.
7. IAM and S3 bucket policies still apply.
8. Gateway endpoints do not have an endpoint hourly charge.

### Healthy Route Table

```text
Destination        Target
10.100.0.0/16      local
pl-xxxxxxxx        vpce-xxxxxxxx
```

Here:

- `pl-xxxxxxxx` represents the AWS-managed S3 prefix list.
- `vpce-xxxxxxxx` represents the S3 Gateway Endpoint.

### Broken Route Table

```text
Destination        Target
10.100.0.0/16      local
```

The S3 prefix-list route is missing.

### Interface Endpoint vs. Gateway Endpoint

| Feature | Interface Endpoint | Gateway Endpoint |
|---|---|---|
| Uses endpoint ENIs | Yes | No |
| Uses security groups | Yes | No |
| Route table association required | Generally no | Yes |
| Endpoint policy | Supported where available | Supported |
| Typical services | SSM, KMS, Secrets Manager | S3, DynamoDB |
| Hourly endpoint charge | Yes | No |

### Important Troubleshooting Principle

An endpoint reporting `available` does not guarantee that every subnet has a route to it.

Always inspect the route table associated with the affected subnet.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- IAM permissions
- EC2 and VPC permissions
- S3 management permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated VPC.
- Create a dedicated test S3 bucket.
- Keep the S3 bucket private.
- Do not modify shared route tables.
- Keep EC2 inbound rules closed.
- Use IAM permissions scoped to the test object.
- Do not introduce public internet access.
- Verify resource ownership before cleanup.

### Cost Considerations

The S3 Gateway Endpoint has no hourly endpoint charge.

However, the following resources may incur charges:

- Two Systems Manager interface endpoints
- EC2 instance
- EBS storage
- S3 requests and storage
- Applicable data transfer

Delete the billable resources after the lab.

---

## 6. Prepare the AWS Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab10"

export VPC_NAME="cloud-lab10-vpc"
export SUBNET_NAME="cloud-lab10-private-subnet"
export RT_NAME="cloud-lab10-private-rt"

export VPC_CIDR="10.100.0.0/16"
export SUBNET_CIDR="10.100.1.0/24"

export EC2_SG_NAME="cloud-lab10-ec2-sg"
export VPCE_SG_NAME="cloud-lab10-ssm-vpce-sg"

export INSTANCE_NAME="cloud-lab10-private-ec2"

export ROLE_NAME="cloud-lab10-ec2-role"
export PROFILE_NAME="cloud-lab10-instance-profile"

export S3_SERVICE="com.amazonaws.${AWS_REGION}.s3"
export SSM_SERVICE="com.amazonaws.${AWS_REGION}.ssm"
export MSG_SERVICE="com.amazonaws.${AWS_REGION}.ssmmessages"
```

Verify AWS identity:

```bash
aws sts get-caller-identity
```

### Step 2 — Generate a Unique Bucket Name

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)

export BUCKET_NAME="cloud-lab10-${ACCOUNT_ID}-$(date +%s)"

echo "$BUCKET_NAME"
```

### Step 3 — Select Availability Zone

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Check endpoint availability:

```bash
aws ec2 describe-vpc-endpoint-services \
  --service-names "$SSM_SERVICE" "$MSG_SERVICE" \
  --query 'ServiceDetails[].{Service:ServiceName,AZs:AvailabilityZones}' \
  --output json \
  --region "$AWS_REGION"
```

Choose an AZ supported by both the instance type and interface endpoint services:

```bash
export LAB_AZ="us-east-1a"
```

### Step 4 — Check Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

If an existing Lab 10 VPC appears, investigate it before creating a duplicate.

---

## 7. Create VPC and Private Subnet

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Enable DNS

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 3 — Create Private Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

Disable public IPv4 assignment:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --no-map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 4 — Create Private Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Associate Route Table

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected initial route:

```text
10.100.0.0/16 → local
```

---

## 8. Create the Private S3 Bucket

### Step 1 — Create Bucket

```bash
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"
```

For `us-east-1`, the bucket creation command does not require a `LocationConstraint`.

### Step 2 — Block Public Access

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region "$AWS_REGION"
```

### Step 3 — Tag Bucket

```bash
aws s3api put-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG}]" \
  --region "$AWS_REGION"
```

### Step 4 — Create Test Object

Create `proof.txt`:

```text
AWS VPC Troubleshooting - Lab 10

Service: Amazon S3
Connection: S3 Gateway Endpoint

Successful object download confirms the
private EC2 instance can access S3.
```

Upload:

```bash
aws s3api put-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  --body proof.txt \
  --region "$AWS_REGION"
```

### Step 5 — Verify Test Object

```bash
aws s3api head-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  --region "$AWS_REGION"
```

Expected: object metadata returned successfully.

---

## 9. Create S3 Gateway Endpoint

### Step 1 — Create Endpoint

```bash
export S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Gateway \
  --service-name "$S3_SERVICE" \
  --route-table-ids "$RT_ID" \
  --tag-specifications \
  "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=cloud-lab10-s3-gateway},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Verify Endpoint

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{ID:VpcEndpointId,State:State,Service:ServiceName,RouteTables:RouteTableIds}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: endpoint `available`, associated with `$RT_ID`.

### Step 3 — Identify S3 Prefix List

```bash
export S3_PREFIX_LIST_ID=$(aws ec2 describe-prefix-lists \
  --filters "Name=prefix-list-name,Values=$S3_SERVICE" \
  --query 'PrefixLists[0].PrefixListId' \
  --output text \
  --region "$AWS_REGION")

echo "$S3_PREFIX_LIST_ID"
```

### Step 4 — Verify S3 Route

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Destination       Target
10.100.0.0/16     local
pl-xxxxxxxx       vpce-xxxxxxxx
```

AWS automatically creates this route when a gateway endpoint is associated with the route table.

Do not manually create the S3 endpoint route.

---

## 10. Configure Security Groups and Systems Manager Endpoints

### Step 1 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name "$EC2_SG_NAME" \
  --description "Lab10 private EC2 security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$EC2_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Interface Endpoint Security Group

```bash
export VPCE_SG_ID=$(aws ec2 create-security-group \
  --group-name "$VPCE_SG_NAME" \
  --description "Lab10 SSM interface endpoint security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$VPCE_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow HTTPS From EC2

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$VPCE_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create SSM Interface Endpoint

```bash
export SSM_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "$SSM_SERVICE" \
  --subnet-ids "$SUBNET_ID" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications \
  "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=cloud-lab10-ssm},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create SSM Messages Endpoint

```bash
export MSG_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "$MSG_SERVICE" \
  --subnet-ids "$SUBNET_ID" \
  --security-group-ids "$VPCE_SG_ID" \
  --private-dns-enabled \
  --tag-specifications \
  "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=cloud-lab10-ssmmessages},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Verify Endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids \
  "$S3_ENDPOINT_ID" \
  "$SSM_ENDPOINT_ID" \
  "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Proceed when all endpoints are `available`.

---

## 11. Configure IAM Permissions

### Step 1 — Create EC2 Trust Policy

Create `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 2 — Create S3 Read Policy

Create `s3-read-policy.json` with the actual bucket name:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::REPLACE_WITH_LAB10_BUCKET/proof.txt"
    }
  ]
}
```

To generate it automatically in WSL2:

```bash
cat > s3-read-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/proof.txt"
    }
  ]
}
EOF
```

### Step 3 — Check Existing IAM Resources

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

`NoSuchEntity` is expected for unused names.

### Step 4 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 5 — Attach Systems Manager Permissions

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 6 — Attach S3 Read Policy

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "cloud-lab10-s3-read" \
  --policy-document file://s3-read-policy.json
```

### Step 7 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM propagation before launching EC2.

---

## 12. Launch Private EC2

### Step 1 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing EC2 Instances

```bash
aws ec2 describe-instances \
  --filters \
  "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Launch Instance

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$EC2_SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for Instance

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Private IP

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `PublicIP` is `null`.

---

## 13. Establish Healthy S3 Connectivity

### Step 1 — Verify Systems Manager Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `Online`.

### Step 2 — Connect Using Session Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Alternatively, use the AWS Console.

### Step 3 — Verify AWS CLI

Inside EC2:

```bash
aws --version
```

Ensure AWS CLI is installed before starting the experiment.

### Step 4 — Configure the Test Bucket Name

Inside EC2:

```bash
export BUCKET_NAME="REPLACE_WITH_YOUR_LAB10_BUCKET"
```

Use the actual bucket name created earlier.

### Step 5 — Download the Test Object

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  /tmp/lab10-proof.txt \
  --region us-east-1 \
  --cli-connect-timeout 5 \
  --cli-read-timeout 10
```

Display:

```bash
cat /tmp/lab10-proof.txt
```

Expected:

```text
AWS VPC Troubleshooting - Lab 10

Service: Amazon S3
Connection: S3 Gateway Endpoint
```

### Step 6 — Verify S3 DNS

```bash
getent ahostsv4 s3.us-east-1.amazonaws.com
```

The gateway endpoint uses S3's service IP ranges, not a private endpoint ENI address.

### Step 7 — Start Background Monitoring

Create a monitoring script inside EC2:

```bash
sudo tee /usr/local/bin/lab10-s3-probe.sh > /dev/null <<'EOF'
#!/bin/bash

BUCKET="$1"
LOG="/var/tmp/vpc-lab10-s3-probe.log"

for i in $(seq 1 120); do

  echo "Time: $(date -u +%FT%TZ)" >> "$LOG"

  if aws s3api get-object \
      --bucket "$BUCKET" \
      --key proof.txt \
      /tmp/lab10-probe-object.txt \
      --region us-east-1 \
      --cli-connect-timeout 3 \
      --cli-read-timeout 5 \
      > /tmp/lab10-probe-output.txt 2>&1; then

    echo "S3_ACCESS=SUCCESS" >> "$LOG"

  else

    echo "S3_ACCESS=FAILED" >> "$LOG"
    tail -n 2 /tmp/lab10-probe-output.txt >> "$LOG"

  fi

  echo "---" >> "$LOG"
  sleep 10

done
EOF
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/lab10-s3-probe.sh
```

Start:

```bash
sudo systemd-run \
  --unit=lab10-s3-probe \
  --collect \
  /usr/local/bin/lab10-s3-probe.sh "$BUCKET_NAME"
```

Verify:

```bash
sudo tail -n 15 /var/tmp/vpc-lab10-s3-probe.log
```

Expected baseline:

```text
S3_ACCESS=SUCCESS
```

Exit Session Manager:

```bash
exit
```

---

## 14. Reproduce the Gateway Endpoint Failure

### Step 1 — Verify the Endpoint Association

From WSL2:

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,RouteTables:RouteTableIds}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: gateway endpoint associated with `$RT_ID`.

### Step 2 — Remove the Route Table Association

```bash
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id "$S3_ENDPOINT_ID" \
  --remove-route-table-ids "$RT_ID" \
  --region "$AWS_REGION"
```

This is the intentional misconfiguration.

### Step 3 — Verify the Missing Association

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,RouteTables:RouteTableIds}' \
  --output json \
  --region "$AWS_REGION"
```

Expected after the modification completes:

```text
State: available
RouteTables: []
```

### Step 4 — Verify the Route Disappeared

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
10.100.0.0/16 → local
```

The S3 prefix-list route is missing.

### Step 5 — Confirm Systems Manager Still Works

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `Online`.

### Step 6 — Reproduce S3 Failure

Reconnect to EC2 using Session Manager.

```bash
export BUCKET_NAME="REPLACE_WITH_YOUR_LAB10_BUCKET"
```

Attempt download:

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  /tmp/lab10-failed-object.txt \
  --region us-east-1 \
  --cli-connect-timeout 5 \
  --cli-read-timeout 10
```

Expected: connection failure or timeout.

### Step 7 — Inspect Monitoring Logs

```bash
sudo tail -n 25 /var/tmp/vpc-lab10-s3-probe.log
```

Expected:

```text
S3_ACCESS=FAILED
```

Exit:

```bash
exit
```

---

## 15. Troubleshooting Investigation

### Check 1 — Inspect Gateway Endpoint

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,Type:VpcEndpointType,Service:ServiceName,RouteTables:RouteTableIds}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the endpoint exists but is not associated with the private route table.

### Check 2 — Inspect Effective Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].{Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: local route exists, but S3 prefix-list route is missing.

### Check 3 — Verify IAM Permissions

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name cloud-lab10-s3-read
```

Finding: the role permits `s3:GetObject` for the test object.

### Check 4 — Verify S3 Bucket and Object

From WSL2:

```bash
aws s3api head-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  --region "$AWS_REGION"
```

Finding: the object exists and is accessible to the local authorized AWS principal.

### Check 5 — Verify VPC DNS

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `True`.

### Check 6 — Verify No Internet Fallback

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected: no default route to NAT or IGW.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Running |
| S3 bucket | Exists |
| S3 object | Exists |
| IAM role | Correct permissions |
| DNS | Working |
| S3 Gateway Endpoint | Available |
| Private route table | Associated with private subnet |
| S3 endpoint route table association | Missing |
| S3 prefix-list route | Missing |
| Internet fallback | None |
| Root cause | Missing gateway endpoint route table association |

---

## 16. Root Cause Analysis

### Root Cause

The S3 Gateway VPC Endpoint was removed from the private subnet's route table associations.

AWS consequently removed the corresponding S3 prefix-list route from that route table.

The EC2 instance had no alternative route to reach S3.

### Technical Explanation

When the EC2 instance requests an S3 object, its network traffic must be routed toward the S3 service.

A gateway endpoint provides a target for the S3 service prefix-list route.

If the private subnet's route table is not associated with the endpoint, the route is absent.

As a result, the EC2 instance cannot reach S3 even if the endpoint resource remains available.

### Root Cause Flow

```text
Private EC2
    |
    v
S3 Object Request
    |
    v
Private Route Table
    |
    X
S3 Prefix-List Route Missing
    |
    X
S3 Request Times Out
```

### Five Whys

1. **Why did the S3 download fail?** The EC2 instance could not reach the S3 service.
2. **Why could EC2 not reach S3?** The route table lacked the S3 gateway endpoint route.
3. **Why was that route missing?** The endpoint was no longer associated with the route table.
4. **Why didn't the available endpoint solve the issue?** Endpoint availability does not guarantee correct subnet routing.
5. **How can this be prevented?** Manage endpoint associations with infrastructure as code and verify effective routing after network changes.

---

## 17. Remediation

### Step 1 — Restore Endpoint Association

From WSL2:

```bash
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id "$S3_ENDPOINT_ID" \
  --add-route-table-ids "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Association

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,RouteTables:RouteTableIds}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `$RT_ID` present.

### Step 3 — Verify S3 Prefix-List Route

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
10.100.0.0/16 → local
pl-xxxxxxxx   → vpce-xxxxxxxx
```

### Step 4 — Verify S3 Download

Reconnect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export BUCKET_NAME="REPLACE_WITH_YOUR_LAB10_BUCKET"
```

Download the object:

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  /tmp/lab10-recovered-object.txt \
  --region us-east-1 \
  --cli-connect-timeout 5 \
  --cli-read-timeout 10
```

Verify file contents:

```bash
cat /tmp/lab10-recovered-object.txt
```

Expected: original test data.

### Step 5 — Review Monitoring Results

```bash
sudo cat /var/tmp/vpc-lab10-s3-probe.log
```

Illustrative results:

```text
S3_ACCESS=SUCCESS
---
S3_ACCESS=FAILED
---
S3_ACCESS=SUCCESS
```

Use the actual timestamps and observations from your test for incident evidence.

### Verification Matrix

| Component | Healthy | Failure | Restored |
|---|---|---|---|
| EC2 | Running | Running | Running |
| S3 bucket | Available | Available | Available |
| IAM | Correct | Correct | Correct |
| Gateway endpoint | Available | Available | Available |
| Endpoint association | Present | Missing | Restored |
| S3 prefix-list route | Present | Missing | Restored |
| S3 download | Successful | Failed | Successful |
| SSM access | Online | Online | Online |

---

## 18. Production Engineering Best Practices

### Gateway Endpoint Troubleshooting Checklist

1. Verify EC2 status.
2. Identify the correct private subnet.
3. Inspect the subnet's effective route table.
4. Verify the S3 gateway endpoint exists.
5. Verify the endpoint service name and region.
6. Check endpoint route table associations.
7. Check the S3 prefix-list route.
8. Verify DNS resolution.
9. Check IAM and endpoint policies.
10. Verify the S3 bucket and object.
11. Investigate security group egress and NACL rules.
12. Restore the required association.
13. Test S3 connectivity from the actual workload.

### Common S3 Access Failures

| Symptom | Potential Cause |
|---|---|
| Connection timeout | Missing route, blocked traffic, or unavailable network path |
| `AccessDenied` | IAM, bucket policy, endpoint policy, or organization-level restrictions |
| `NoSuchKey` | Incorrect object key |
| `NoSuchBucket` | Incorrect bucket name |
| Wrong-region behavior | Incorrect region or S3 endpoint selection |
| Endpoint available but S3 unavailable | Incorrect route table association |
| DNS resolution failure | Resolver or DNS configuration problem |

### Prevention

- Manage VPC endpoints using Terraform.
- Review route table association changes through pull requests.
- Restrict endpoint modification permissions.
- Maintain clear resource ownership tags.
- Monitor application-level S3 access failures.
- Verify private subnet routing after deployments.
- Use least-privilege IAM and endpoint policies.
- Avoid unnecessary public internet paths in private workloads.

---

## 19. Interview Questions and Answers

### Q1. What is an S3 Gateway Endpoint?

It enables VPC resources to access Amazon S3 privately using a gateway endpoint route instead of NAT or an internet gateway.

### Q2. Does an S3 Gateway Endpoint have a security group?

No. Gateway endpoints do not create endpoint ENIs or attach endpoint security groups.

### Q3. What is an S3 prefix list?

An AWS-managed collection of IP address ranges for Amazon S3, used as a destination in gateway endpoint routes.

### Q4. Why must a gateway endpoint be associated with route tables?

The association allows AWS to add the endpoint route to the selected tables.

### Q5. What happens when the route table association is removed?

AWS removes the S3 gateway endpoint route from the affected route table.

### Q6. Can the endpoint remain available while traffic fails?

Yes. The endpoint can be available without being associated with the workload's route table.

### Q7. Why didn't IAM permissions fix the problem?

IAM authorization cannot restore a missing network route.

### Q8. What is the difference between `AccessDenied` and a timeout?

`AccessDenied` means an API request was rejected by an authorization control. A timeout commonly indicates a failure to establish or complete network communication.

### Q9. Why did Session Manager continue working?

The instance used separate `ssm` and `ssmmessages` interface endpoints that were unaffected by the S3 route table change.

### Q10. How is this different from Lab 09?

Lab 09 investigates interface endpoint security group rules. Lab 10 investigates gateway endpoint route table associations.

### Q11. Is an S3 Gateway Endpoint free?

Gateway endpoints do not have a dedicated endpoint hourly or data-processing charge. S3 usage and other applicable AWS charges can still apply.

### Q12. How would you explain this lab in an interview?

> I deployed a private EC2 instance, S3 Gateway VPC Endpoint, and private S3 bucket in an isolated AWS VPC. After confirming that the instance could download an object using an IAM role, I intentionally removed the endpoint's route table association. The endpoint remained available, but the S3 prefix-list route disappeared and downloads failed. I investigated the endpoint state, route table, bucket, and IAM permissions, identified the missing association, restored it, and verified successful S3 access without a NAT Gateway or Internet Gateway.

---

## 20. Cleanup

**Important:** Confirm all resources belong to `VPC-Troubleshooting-Lab10` before deletion. Never delete unrelated buckets or shared network resources.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids \
  "$S3_ENDPOINT_ID" "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws s3api get-bucket-tagging \
  --bucket "$BUCKET_NAME"
```

### Step 2 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination`:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 3 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete VPC Endpoints

```bash
aws ec2 delete-vpc-endpoints \
  --vpc-endpoint-ids \
  "$S3_ENDPOINT_ID" \
  "$SSM_ENDPOINT_ID" \
  "$MSG_ENDPOINT_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm all endpoint network interfaces have been removed:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Delete Security Groups

Remove the security group reference:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$VPCE_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

Delete security groups:

```bash
aws ec2 delete-security-group \
  --group-id "$VPCE_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Delete IAM Permissions

Verify the role belongs to this lab:

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Delete the inline S3 policy:

```bash
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name cloud-lab10-s3-read
```

Detach SSM permissions:

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Remove and delete the instance profile:

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 7 — Delete Private Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete Dedicated VPC

Verify no remaining network interfaces or dependencies:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Delete:

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Verify S3 Bucket Contents

```bash
aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" \
  --query 'Contents[].Key' \
  --output table \
  --region "$AWS_REGION"
```

Expected: only `proof.txt`.

### Step 11 — Delete Test Object

```bash
aws s3api delete-object \
  --bucket "$BUCKET_NAME" \
  --key proof.txt \
  --region "$AWS_REGION"
```

### Step 12 — Delete Test Bucket

```bash
aws s3api delete-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"
```

Only delete the bucket after confirming it belongs exclusively to this lab and contains no unrelated data.

### Step 13 — Verify Final Cleanup

Check active EC2 instances:

```bash
aws ec2 describe-instances \
  --filters \
  "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Verify EBS volume deletion:

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

`InvalidVolume.NotFound` indicates that the volume was removed.

Also verify that all three endpoints and the S3 bucket are deleted.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| S3 Gateway Endpoint | Deleted |
| SSM Interface Endpoint | Deleted |
| SSM Messages Endpoint | Deleted |
| Endpoint ENIs | Removed |
| EC2 security group | Deleted |
| Endpoint security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Private route table | Deleted |
| Private subnet | Deleted |
| Dedicated VPC | Deleted |
| Test S3 object | Deleted |
| Test S3 bucket | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
10-s3-gateway-endpoint-misconfiguration/
├── README.md
├── ec2-trust-policy.json
├── s3-read-policy.json
└── proof.txt
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation, reproduction, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | Allows EC2 to assume the IAM role |
| `s3-read-policy.json` | Grants read access to the lab test object |
| `proof.txt` | Test object uploaded to the private S3 bucket |

The `s3-read-policy.json` file must use the actual bucket name generated for the lab.

Do not commit AWS credentials, access keys, private keys, or sensitive account information.

---

## 22. Lessons Learned

This lab demonstrates that an S3 Gateway VPC Endpoint can remain available while private EC2 instances cannot reach Amazon S3.

The root cause was not the S3 bucket, IAM permissions, DNS, or EC2 instance.

The issue occurred because the gateway endpoint was no longer associated with the private subnet's route table.

Removing the association caused the AWS-managed S3 prefix-list route to disappear.

Restoring the association automatically restored the route and allowed the EC2 instance to download the object again.

This lab also demonstrates the difference between network failures and authorization failures.

**Key Lesson:** When troubleshooting S3 access through a gateway endpoint, always inspect the endpoint's route table associations and the effective S3 prefix-list route.

---

## 23. Skills Demonstrated

- AWS VPC private networking
- S3 Gateway VPC Endpoints
- AWS-managed prefix lists
- Route table troubleshooting
- Gateway endpoint association management
- S3 private access
- IAM least-privilege permissions
- S3 object retrieval
- AWS Systems Manager
- Interface endpoint management
- AWS CLI v2
- Linux troubleshooting
- Background connectivity testing
- Root cause analysis
- Incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-010 |
| Problem | Private EC2 cannot access S3 |
| Gateway Endpoint | Available |
| Root Cause | Missing route table association |
| S3 Prefix-List Route | Missing during incident |
| IAM Permissions | Correct |
| S3 Bucket | Available |
| Remediation | Restore endpoint association |
| Route After Fix | Restored |
| S3 Download After Fix | Successful |
| Public Internet Required | No |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** S3 Gateway VPC Endpoints depend on correct route table associations. An available endpoint does not guarantee connectivity if the subnet's route table does not contain the required S3 prefix-list route.
