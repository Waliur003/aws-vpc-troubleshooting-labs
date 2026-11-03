# Lab 13 — VPC Flow Logs Not Delivering

## Overview

This lab demonstrates how to troubleshoot an AWS VPC Flow Logs delivery failure caused by missing IAM permissions.

We create a dedicated VPC, deploy an EC2 instance, and configure VPC Flow Logs to send network traffic metadata to Amazon CloudWatch Logs.

Initially, the Flow Log successfully publishes records to the CloudWatch log group.

We intentionally remove the IAM policy that allows the VPC Flow Logs service to publish records. The EC2 instance continues generating traffic, but log delivery fails.

We investigate the delivery status, CloudWatch log group, IAM role, and permissions to identify the root cause.

After restoring the required IAM policy, we verify that new Flow Log records are delivered successfully.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce Failure → Investigate → Identify Root Cause → Remediate → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-013 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, CloudWatch Logs, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl |
| VPC CIDR | `10.130.0.0/16` |
| Public Subnet | `10.130.1.0/24` |
| Flow Log Resource Type | VPC |
| Captured Traffic | `ALL` |
| Maximum Aggregation Interval | 60 seconds |
| Destination | CloudWatch Logs |
| Log Group | `/aws/vpc/cloud-lab13-flowlogs` |
| IAM Delivery Role | `cloud-lab13-flowlogs-role` |
| Simulated Failure | IAM delivery policy removed |
| Root Cause | Missing CloudWatch Logs permissions |
| Remediation | Restore IAM delivery policy |
| Verification | Successful delivery status and new log events |

---

## 2. Production Incident Scenario

### Incident Description

A company enables VPC Flow Logs to monitor network activity across its AWS infrastructure.

The security operations team relies on these records to investigate suspicious connections, rejected traffic, and network connectivity problems.

During a routine investigation, engineers discover that new network records are no longer appearing in the CloudWatch log group.

The EC2 instances remain operational, and applications are still communicating with external services.

The VPC Flow Log resource also continues to exist.

However, the IAM role assigned to deliver records to CloudWatch Logs has lost its necessary permissions.

### Incident Symptoms

- No new Flow Log records appear in CloudWatch Logs.
- Existing historical log records remain visible.
- EC2 network connectivity continues working.
- The Flow Log resource can remain `ACTIVE`.
- Delivery status may change to `FAILED`.
- The delivery error may report `Access error`.
- The IAM delivery role no longer has the required CloudWatch Logs policy.

### Business Impact

- Security analysts lose network visibility.
- Network incident investigations become harder.
- Traffic monitoring becomes incomplete.
- Network troubleshooting takes longer.
- Detection and audit workflows may lack important records.
- Security monitoring effectiveness decreases.

### Incident Objective

Identify the reason Flow Logs cannot publish new records to CloudWatch Logs and restore the monitoring pipeline without interrupting application networking.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                         Internet
                            |
                     Internet Gateway
                            |
               +-------------------------+
               | AWS VPC                 |
               | 10.130.0.0/16           |
               |                         |
               | Public Subnet           |
               | 10.130.1.0/24           |
               |                         |
               | EC2 Instance            |
               | Generates HTTPS Traffic |
               +-------------------------+
                            |
                            v
                       VPC Flow Logs
                            |
                            v
                     IAM Delivery Role
                            |
                     CloudWatch Permissions
                            |
                            v
                     CloudWatch Logs
                            |
                            v
                     Log Events Delivered
```

### Broken Architecture

```text
                      EC2 Network Traffic
                              |
                              v
                         VPC Flow Logs
                              |
                              v
                       IAM Delivery Role
                              |
                              X
                       IAM Policy Missing
                              |
                              X
                       Delivery Failure
                              |
                              X
                       CloudWatch Logs
                       No New Records
```

### Architecture Components

| Component | Purpose |
|---|---|
| VPC | Contains the network resources being monitored |
| Public subnet | Hosts the test instance |
| EC2 instance | Generates network traffic |
| Internet Gateway | Provides internet connectivity |
| Security group | Controls instance traffic |
| VPC Flow Logs | Captures supported network-flow metadata |
| IAM delivery role | Authorizes publication to CloudWatch Logs |
| CloudWatch log group | Stores delivered records |
| Systems Manager | Provides remote management access |

### Important Distinction

VPC Flow Logs monitors network activity but does not control whether traffic is allowed or denied.

A Flow Logs delivery problem does not automatically mean VPC networking is broken.

---

## 4. Understanding VPC Flow Logs

Amazon VPC Flow Logs records information about supported IP traffic flowing through network interfaces.

Flow Logs can be configured at three scopes:

1. VPC
2. Subnet
3. Network interface

This lab creates a Flow Log for the entire VPC.

### Captured Information

A typical Flow Log record contains:

- AWS account ID
- Network interface ID
- Source IP address
- Destination IP address
- Source port
- Destination port
- Protocol number
- Packet count
- Byte count
- Start and end timestamps
- Traffic action
- Log status

### Traffic Types

| Traffic Type | Description |
|---|---|
| `ACCEPT` | Captures supported accepted traffic |
| `REJECT` | Captures supported rejected traffic |
| `ALL` | Captures both categories |

### Example Record

```text
2 123456789012 eni-0123456789abcdef0 10.130.1.10 93.184.215.14 49152 443 6 10 7200 1760000000 1760000060 ACCEPT OK
```

This is an illustrative record, not actual lab evidence.

### VPC Flow Logs vs. CloudTrail

| Feature | VPC Flow Logs | AWS CloudTrail |
|---|---|---|
| Purpose | Network traffic visibility | AWS API activity visibility |
| Tracks source/destination IP | Yes | Sometimes, as API context |
| Tracks network ports | Yes | Not as network-flow records |
| Tracks AWS API calls | No | Yes |
| Used for | Network analysis and security monitoring | Auditing and API investigation |

### Delivery Destinations

VPC Flow Logs supports delivery to:

- Amazon CloudWatch Logs
- Amazon S3
- Amazon Data Firehose

This lab uses CloudWatch Logs.

### Delivery Delay

Flow Log records are aggregated and delivered asynchronously.

CloudWatch delivery commonly takes several minutes, and initial setup or other conditions can introduce additional delays.

Therefore, do not conclude that log delivery is broken simply because records do not appear immediately.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Python or common Linux tools
- EC2/VPC permissions
- IAM management permissions
- CloudWatch Logs permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated test VPC.
- Keep inbound EC2 rules closed.
- Do not remove policies from shared IAM roles.
- Use separate EC2 and Flow Logs delivery roles.
- Verify resource tags before destructive changes.
- Save evidence before deleting CloudWatch logs.
- Delete temporary resources after the exercise.

### Cost Considerations

This lab may incur charges for:

- EC2 compute
- EBS storage
- Public IPv4 address
- CloudWatch Logs ingestion and storage
- Applicable data transfer

Use a short log retention period and clean up afterward.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab13"

export VPC_CIDR="10.130.0.0/16"
export SUBNET_CIDR="10.130.1.0/24"

export VPC_NAME="cloud-lab13-vpc"
export SUBNET_NAME="cloud-lab13-public-subnet"
export IGW_NAME="cloud-lab13-igw"
export RT_NAME="cloud-lab13-public-rt"

export SG_NAME="cloud-lab13-ec2-sg"
export INSTANCE_NAME="cloud-lab13-ec2"

export EC2_ROLE_NAME="cloud-lab13-ssm-role"
export EC2_PROFILE_NAME="cloud-lab13-ssm-profile"

export FLOW_ROLE_NAME="cloud-lab13-flowlogs-role"
export FLOW_POLICY_NAME="cloud-lab13-flowlogs-delivery"

export LOG_GROUP_NAME="/aws/vpc/cloud-lab13-flowlogs"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)
```

### Step 2 — Verify AWS Identity

```bash
aws sts get-caller-identity
aws --version
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

Select an AZ supported by your account:

```bash
export LAB_AZ="us-east-1a"
```

### Step 4 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Check the CloudWatch log group:

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP_NAME" \
  --query 'logGroups[].logGroupName' \
  --output table \
  --region "$AWS_REGION"
```

Inspect existing resources before creating new ones.

---

## 7. Create VPC Networking

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

### Step 3 — Create Public Subnet

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

Enable automatic public IPv4 assignment:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 4 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

Attach:

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Associate Subnet

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 8 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.130.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure EC2 Security and IAM

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab13 flow logs test instance" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Keep inbound rules empty.

The default outbound rule permits test HTTPS connections.

### Step 2 — Create EC2 Trust Policy

Save as `ec2-trust-policy.json`:

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

### Step 3 — Check IAM Resources

```bash
aws iam get-role \
  --role-name "$EC2_ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$EC2_PROFILE_NAME"
```

For unused names, `NoSuchEntity` is expected.

### Step 4 — Create EC2 IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 5 — Attach Systems Manager Policy

```bash
aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 6 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$EC2_PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$EC2_PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM propagation before launching EC2.

---

## 9. Create Network Traffic Generator

Create `traffic-user-data.sh`:

```bash
#!/bin/bash
set -eu

cat > /usr/local/bin/lab13-traffic.sh <<'SCRIPT'
#!/bin/bash

for i in $(seq 1 360); do

  curl -4 -sS \
    --noproxy '*' \
    --connect-timeout 3 \
    --max-time 8 \
    https://example.com \
    -o /dev/null || true

  sleep 10

done
SCRIPT

chmod +x /usr/local/bin/lab13-traffic.sh

systemd-run \
  --unit=lab13-traffic \
  --collect \
  /usr/local/bin/lab13-traffic.sh
```

### Explanation

This script:

1. Creates a Bash traffic generator.
2. Sends repeated HTTPS requests to `example.com`.
3. Generates network traffic for Flow Logs.
4. Runs independently using systemd.
5. Stops after 360 iterations, approximately one hour plus request time.

The script generates normal outgoing HTTPS traffic, not malicious network traffic.

If the experiment takes longer than the generator's runtime, restart it inside EC2 before validating new records.

---

## 10. Launch EC2

### Step 1 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instances

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
  --iam-instance-profile "Name=$EC2_PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://traffic-user-data.sh \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Instance

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 6 — Connect Using SSM

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl status lab13-traffic.service --no-pager
```

Test network connectivity:

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTPS response.

Exit the EC2 session.

---

## 11. Configure CloudWatch Logs

### Step 1 — Create Log Group

```bash
aws logs create-log-group \
  --log-group-name "$LOG_GROUP_NAME" \
  --tags Project="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Set Log Retention

```bash
aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP_NAME" \
  --retention-in-days 1 \
  --region "$AWS_REGION"
```

### Step 3 — Verify Log Group

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP_NAME" \
  --query 'logGroups[].{Name:logGroupName,Retention:retentionInDays}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the dedicated log group exists with one-day retention.

---

## 12. Configure Flow Logs IAM Delivery Role

### Step 1 — Create Flow Logs Trust Policy

Create `flowlogs-trust-policy.json` using the actual AWS account and region:

```bash
cat > flowlogs-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${ACCOUNT_ID}"
        },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:vpc-flow-log/*"
        }
      }
    }
  ]
}
EOF
```

The service principal `vpc-flow-logs.amazonaws.com` allows VPC Flow Logs to assume this role.

The source-account and source-ARN conditions restrict the trusted service context.

### Step 2 — Create Delivery Permissions Policy

Create `flowlogs-delivery-policy.json`:

```bash
cat > flowlogs-delivery-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeCloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PublishLab13FlowLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP_NAME}:*"
    }
  ]
}
EOF
```

### Required IAM Actions

| Action | Purpose |
|---|---|
| `logs:DescribeLogGroups` | Inspect available log groups |
| `logs:DescribeLogStreams` | Inspect log streams |
| `logs:CreateLogStream` | Create streams for flow records |
| `logs:PutLogEvents` | Publish log records |

The log group is created separately in this lab, so the delivery role does not need permission to create it.

### Step 3 — Create the Delivery Role

```bash
aws iam create-role \
  --role-name "$FLOW_ROLE_NAME" \
  --assume-role-policy-document file://flowlogs-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 4 — Attach the Inline Policy

```bash
aws iam put-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME" \
  --policy-document file://flowlogs-delivery-policy.json
```

### Step 5 — Verify IAM Role

```bash
aws iam get-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME"
```

Retrieve ARN:

```bash
export FLOW_ROLE_ARN=$(aws iam get-role \
  --role-name "$FLOW_ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)

echo "$FLOW_ROLE_ARN"
```

Allow IAM changes to propagate.

---

## 13. Enable VPC Flow Logs

### Step 1 — Check Existing Flow Logs

```bash
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[].{ID:FlowLogId,Status:FlowLogStatus,Delivery:DeliverLogsStatus}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 2 — Create Flow Log

```bash
export FLOW_LOG_ID=$(aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids "$VPC_ID" \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name "$LOG_GROUP_NAME" \
  --deliver-logs-permission-arn "$FLOW_ROLE_ARN" \
  --max-aggregation-interval 60 \
  --tag-specifications \
  "ResourceType=vpc-flow-log,Tags=[{Key=Name,Value=cloud-lab13-flowlogs},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'FlowLogIds[0]' \
  --output text \
  --region "$AWS_REGION")

echo "$FLOW_LOG_ID"
```

### Step 3 — Verify Configuration

```bash
aws ec2 describe-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --query 'FlowLogs[].{ID:FlowLogId,Status:FlowLogStatus,Delivery:DeliverLogsStatus,Error:DeliverLogsErrorMessage,Role:DeliverLogsPermissionArn}' \
  --output json \
  --region "$AWS_REGION"
```

Healthy expected values:

```text
FlowLogStatus: ACTIVE
DeliverLogsStatus: SUCCESS
```

### Step 4 — Inspect Log Streams

```bash
aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP_NAME" \
  --query 'logStreams[].{Name:logStreamName,LastEvent:lastEventTimestamp}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Inspect Actual Log Records

```bash
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP_NAME" \
  --limit 10 \
  --query 'events[].{Timestamp:timestamp,Message:message}' \
  --output table \
  --region "$AWS_REGION"
```

Verify actual records before introducing the fault.

### Important

Flow Logs delivery is asynchronous.

A delay during initial setup is normal. Confirm the log status and baseline records rather than treating a short delay as an incident.

---

## 14. Reproduce the Flow Logs Delivery Failure

### Step 1 — Verify Delivery IAM Policy

```bash
aws iam list-role-policies \
  --role-name "$FLOW_ROLE_NAME" \
  --output json
```

Expected:

```text
cloud-lab13-flowlogs-delivery
```

### Step 2 — Remove the Delivery Policy

```bash
aws iam delete-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME"
```

This is the intentional fault injection.

### Step 3 — Confirm the Policy Is Missing

```bash
aws iam list-role-policies \
  --role-name "$FLOW_ROLE_NAME" \
  --output json
```

Expected:

```json
{
  "PolicyNames": []
}
```

### Step 4 — Inspect Flow Logs Delivery Status

```bash
aws ec2 describe-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --query 'FlowLogs[].{Status:FlowLogStatus,Delivery:DeliverLogsStatus,Error:DeliverLogsErrorMessage}' \
  --output json \
  --region "$AWS_REGION"
```

After the permission change takes effect, expected findings may include:

```text
FlowLogStatus: ACTIVE
DeliverLogsStatus: FAILED
DeliverLogsErrorMessage: Access error
```

The exact error and timing can vary.

Existing AWS service credentials may remain valid temporarily, and delivery status updates are asynchronous.

### Step 5 — Verify EC2 Still Works

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceStatus.Status,System:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: healthy status checks.

### Step 6 — Verify Network Connectivity

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTPS connectivity.

Exit Session Manager.

### Failure Summary

| Component | Expected Finding |
|---|---|
| EC2 | Running |
| Network connectivity | Working |
| VPC Flow Log | Exists |
| CloudWatch log group | Exists |
| IAM delivery role | Exists |
| IAM delivery policy | Missing |
| New log delivery | Failing after permissions take effect |
| Root cause | Missing CloudWatch Logs permissions |

---

## 15. Troubleshooting Investigation

### Check 1 — Verify Flow Log State

```bash
aws ec2 describe-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --query 'FlowLogs[0].{Status:FlowLogStatus,Delivery:DeliverLogsStatus,Error:DeliverLogsErrorMessage}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the Flow Log can remain active while delivery fails.

### Check 2 — Verify CloudWatch Log Group

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP_NAME" \
  --query 'logGroups[].{Name:logGroupName,Retention:retentionInDays}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: the destination exists.

### Check 3 — Inspect Recent Events

```bash
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP_NAME" \
  --start-time "$(($(date +%s) * 1000 - 900000))" \
  --limit 20 \
  --query 'events[].{Timestamp:timestamp,Message:message}' \
  --output table \
  --region "$AWS_REGION"
```

Historical records may remain visible. Check event times rather than assuming existing records indicate healthy current delivery.

### Check 4 — Verify IAM Role Trust Policy

```bash
aws iam get-role \
  --role-name "$FLOW_ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json
```

Finding: the Flow Logs service principal remains trusted.

### Check 5 — Inspect Inline Policies

```bash
aws iam list-role-policies \
  --role-name "$FLOW_ROLE_NAME" \
  --output json
```

Finding: required delivery policy is missing.

### Check 6 — Inspect Managed Policies

```bash
aws iam list-attached-role-policies \
  --role-name "$FLOW_ROLE_NAME" \
  --output json
```

Finding: no alternative attached policy grants the required delivery permissions.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Healthy |
| Internet connectivity | Working |
| VPC Flow Log | Exists |
| CloudWatch Logs group | Exists |
| IAM trust | Correct |
| IAM delivery policy | Missing |
| CloudWatch write permission | Not granted |
| Log delivery | Failing |
| Root cause | Delivery role permissions removed |

---

## 16. Root Cause Analysis

### Root Cause

The IAM role used by the VPC Flow Logs service no longer had permission to publish records to CloudWatch Logs.

### Technical Explanation

VPC Flow Logs needs an IAM role to deliver records to CloudWatch Logs.

The delivery role must trust the VPC Flow Logs service and contain the required CloudWatch Logs permissions.

In this lab, the role's trust relationship remained correct.

However, we removed its inline IAM policy, including permission to create log streams and publish events.

As a result, the monitoring pipeline could not publish new records even though network traffic continued.

### Root Cause Flow

```text
EC2 Network Traffic
        |
        v
VPC Flow Logs
        |
        v
IAM Delivery Role
        |
        X
CloudWatch Permissions Missing
        |
        X
PutLogEvents Not Authorized
        |
        X
New Log Records Not Delivered
```

### Five Whys

1. **Why were new VPC Flow Logs missing?** The delivery pipeline could not publish records.
2. **Why could it not publish records?** The delivery role lacked CloudWatch Logs permissions.
3. **Why were the permissions missing?** The IAM inline policy was removed.
4. **Why did networking continue working?** Flow Logs monitors traffic but does not control the packet forwarding path.
5. **How can the incident be prevented?** Manage delivery roles with infrastructure as code, review IAM changes, and monitor delivery status.

---

## 17. Remediation

### Step 1 — Restore IAM Delivery Policy

From WSL2:

```bash
aws iam put-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME" \
  --policy-document file://flowlogs-delivery-policy.json
```

### Step 2 — Verify Policy

```bash
aws iam get-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME"
```

Verify the policy includes:

```text
logs:DescribeLogGroups
logs:DescribeLogStreams
logs:CreateLogStream
logs:PutLogEvents
```

### Step 3 — Verify Delivery Status

```bash
aws ec2 describe-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --query 'FlowLogs[].{Status:FlowLogStatus,Delivery:DeliverLogsStatus,Error:DeliverLogsErrorMessage}' \
  --output json \
  --region "$AWS_REGION"
```

Expected after recovery:

```text
FlowLogStatus: ACTIVE
DeliverLogsStatus: SUCCESS
```

### Step 4 — Generate Fresh Network Traffic

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
for i in {1..10}; do
  curl -4 -sS \
    --noproxy '*' \
    --connect-timeout 5 \
    --max-time 10 \
    https://example.com \
    -o /dev/null
done
```

Exit Session Manager.

### Step 5 — Check New CloudWatch Events

From WSL2:

```bash
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP_NAME" \
  --start-time "$(($(date +%s) * 1000 - 900000))" \
  --limit 30 \
  --query 'events[].{Timestamp:timestamp,Message:message}' \
  --output table \
  --region "$AWS_REGION"
```

Inspect actual record timestamps and confirm that events were generated after the policy was restored.

Allow for normal Flow Logs aggregation and publication delays.

### Verification Matrix

| Check | Baseline | During Failure | After Fix |
|---|---|---|---|
| EC2 | Running | Running | Running |
| Network traffic | Working | Working | Working |
| Flow Log resource | Active | Can remain active | Active |
| CloudWatch log group | Exists | Exists | Exists |
| IAM delivery role | Exists | Exists | Exists |
| Delivery policy | Present | Missing | Restored |
| Delivery status | Success | Failure expected | Success |
| New log records | Delivered | Delivery fails | Delivered |

### Success Criteria

The lab is considered successful when:

- Flow Logs initially delivers real records.
- The IAM delivery policy is removed.
- A relevant delivery failure is observed.
- The permission issue is identified.
- The policy is restored.
- Delivery status recovers.
- New traffic records appear in CloudWatch Logs.

---

## 18. Production Best Practices

### VPC Flow Logs Troubleshooting Checklist

1. Confirm the Flow Log resource exists.
2. Verify `FlowLogStatus`.
3. Inspect `DeliverLogsStatus`.
4. Check `DeliverLogsErrorMessage`.
5. Verify the destination log group exists.
6. Verify the IAM role exists.
7. Inspect the role trust policy.
8. Inspect the CloudWatch Logs permissions.
9. Confirm network activity is present.
10. Account for aggregation and delivery latency.
11. Restore missing IAM permissions.
12. Verify new records after remediation.

### Common Failure Scenarios

| Symptom | Possible Cause |
|---|---|
| `Access error` | Missing IAM permissions or incorrect role trust |
| Log group not found | Incorrect or deleted destination |
| No new records immediately | Normal delivery delay or insufficient traffic |
| Flow Log active but delivery failed | Destination or authorization problem |
| `SKIPDATA` | Some records were skipped during aggregation |
| `NODATA` | No network traffic was observed for the reporting interval |
| Unexpectedly high log volume | Excessive traffic or overly broad capture scope |

### Prevention

- Use Terraform to manage VPC Flow Logs.
- Protect delivery IAM roles against accidental modification.
- Use least-privilege IAM permissions.
- Apply CloudWatch retention policies.
- Monitor delivery errors and log arrival.
- Include monitoring resources in deployment reviews.
- Use separate roles for workloads and service log delivery.
- Verify log records after important infrastructure changes.
- Review log ingestion costs.

---

## 19. Interview Questions and Answers

### Q1. What are VPC Flow Logs?

VPC Flow Logs captures metadata about supported IP traffic flowing through network interfaces associated with a VPC, subnet, or network interface.

### Q2. Can VPC Flow Logs capture packet payloads?

No. It captures network-flow metadata rather than complete packet contents.

### Q3. What destinations support VPC Flow Logs?

CloudWatch Logs, Amazon S3, and Amazon Data Firehose.

### Q4. What IAM principal is used for CloudWatch Flow Logs delivery?

`vpc-flow-logs.amazonaws.com`.

### Q5. What CloudWatch permissions are required?

Important permissions include `logs:CreateLogStream` and `logs:PutLogEvents`, along with appropriate describe permissions.

### Q6. What does `FlowLogStatus=ACTIVE` mean?

The Flow Log resource is active. It does not, by itself, prove that log events are being delivered successfully.

### Q7. What does `DeliverLogsStatus=FAILED` mean?

The service is reporting a problem delivering records to the configured destination.

### Q8. What can cause an `Access error`?

Insufficient delivery-role IAM permissions or an incorrect role trust policy.

### Q9. Does VPC Flow Logs block network traffic?

No. It monitors supported network traffic metadata.

### Q10. Why might logs not appear immediately?

Flow Logs uses aggregation and asynchronous delivery, which introduces latency.

### Q11. What is the difference between CloudTrail and VPC Flow Logs?

CloudTrail records supported AWS API activity, while VPC Flow Logs records network traffic metadata.

### Q12. How would you describe this lab in an interview?

> I configured VPC Flow Logs to deliver network traffic records from an AWS VPC to CloudWatch Logs. After verifying successful delivery, I intentionally removed the IAM policy from the Flow Logs delivery role. The EC2 instance continued generating traffic, but new log delivery failed. I investigated the Flow Log delivery status, CloudWatch destination, IAM role, and permissions. After identifying the missing policy, I restored it and confirmed that new records were delivered successfully.

---

## 20. Cleanup

**Important:** Verify every resource belongs to `VPC-Troubleshooting-Lab13` before deletion. Export any evidence you need before deleting the log group.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --query 'FlowLogs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws iam list-role-tags \
  --role-name "$FLOW_ROLE_NAME"
```

### Step 2 — Delete VPC Flow Log

```bash
aws ec2 delete-flow-logs \
  --flow-log-ids "$FLOW_LOG_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[].FlowLogId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 3 — Delete CloudWatch Log Group

Verify the group's tag and contents before deleting:

```bash
aws logs list-tags-for-resource \
  --resource-arn "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP_NAME}" \
  --region "$AWS_REGION"
```

Delete:

```bash
aws logs delete-log-group \
  --log-group-name "$LOG_GROUP_NAME" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Flow Logs Delivery Role

Remove the inline policy:

```bash
aws iam delete-role-policy \
  --role-name "$FLOW_ROLE_NAME" \
  --policy-name "$FLOW_POLICY_NAME"
```

Delete the role:

```bash
aws iam delete-role \
  --role-name "$FLOW_ROLE_NAME"
```

### Step 5 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination` is enabled.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete Security Group

Ensure there are no remaining ENI dependencies:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Delete:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete EC2 IAM Role and Profile

Verify ownership:

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Detach policy:

```bash
aws iam detach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Remove role from profile:

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$EC2_PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Delete:

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$EC2_PROFILE_NAME"

aws iam delete-role \
  --role-name "$EC2_ROLE_NAME"
```

### Step 9 — Delete Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Internet Gateway

Detach:

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

Delete:

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Verify VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Continue only after confirming no remaining dependent resources.

### Step 13 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Final Verification

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

Verify the root EBS volume was deleted:

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

An `InvalidVolume.NotFound` response indicates successful removal.

Also confirm the Flow Log, log group, and dedicated IAM roles have been deleted.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| VPC Flow Log | Deleted |
| CloudWatch log group | Deleted |
| Flow Logs IAM policy | Deleted |
| Flow Logs delivery role | Deleted |
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| EC2 security group | Deleted |
| EC2 IAM role | Deleted |
| EC2 instance profile | Deleted |
| Public route table | Deleted |
| Public subnet | Deleted |
| Internet Gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
13-flow-logs-not-delivering/
├── README.md
├── ec2-trust-policy.json
├── flowlogs-trust-policy.json
├── flowlogs-delivery-policy.json
└── traffic-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete lab documentation, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | Allows EC2 to assume the Systems Manager role |
| `flowlogs-trust-policy.json` | Allows the VPC Flow Logs service to assume the delivery role |
| `flowlogs-delivery-policy.json` | Grants CloudWatch Logs publishing permissions |
| `traffic-user-data.sh` | Generates network activity from the EC2 instance |

The IAM JSON files should be generated using the actual account ID and Region variables, as shown in the setup commands.

Do not commit AWS credentials, access keys, or private account information.

---

## 22. Lessons Learned

This lab demonstrates how VPC Flow Logs can stop delivering network records even when the monitored VPC and EC2 instance are functioning correctly.

The network was not the cause of the incident.

The actual problem was that the IAM role used for CloudWatch Logs delivery no longer contained the necessary permissions.

Removing the IAM policy prevented the Flow Logs service from publishing new records.

Restoring the policy allowed log delivery to recover.

The exercise also demonstrates why delivery status, IAM permissions, and actual CloudWatch log events should all be checked during troubleshooting.

**Key Lesson:** When VPC Flow Logs stops delivering records, inspect the IAM delivery role, CloudWatch destination, delivery status, and error messages before assuming the VPC networking itself is broken.

---

## 23. Skills Demonstrated

- AWS VPC Flow Logs
- CloudWatch Logs configuration
- IAM service trust policies
- CloudWatch log publishing permissions
- Flow Logs delivery troubleshooting
- Network monitoring and visibility
- AWS CLI v2
- EC2 traffic generation
- IAM permission fault injection
- CloudWatch log analysis
- Root cause analysis
- Monitoring pipeline remediation
- Infrastructure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-013 |
| Problem | VPC Flow Logs records not delivering |
| Root Cause | IAM delivery policy removed |
| EC2 Network | Working |
| Flow Log Resource | Active |
| CloudWatch Log Group | Exists during incident |
| IAM Trust | Correct |
| Delivery Permissions | Missing during incident |
| Remediation | Restore delivery policy |
| Delivery After Fix | Successful |
| New Log Records | Delivered |
| Cleanup | Temporary resources deleted |
| Expected Incident Status | Resolved |

**Key Takeaway:** VPC Flow Logs requires correct IAM permissions to deliver network traffic metadata to CloudWatch Logs. A Flow Log resource can remain active while its delivery pipeline fails.
