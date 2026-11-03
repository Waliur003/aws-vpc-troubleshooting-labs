# Lab 14 — VPC Reachability Analyzer Investigation

## Overview

This lab demonstrates how to use AWS VPC Reachability Analyzer to investigate an EC2-to-EC2 connectivity failure caused by an incorrectly configured security group.

We deploy two EC2 instances in separate subnets of the same VPC. The first instance acts as an HTTP client, and the second hosts a Python HTTP server on port 8080.

The server's security group initially has no inbound rule allowing traffic from the client.

We use Reachability Analyzer to investigate the connection, identify the blocking security group, restore the required inbound rule, and run another analysis to verify the network path.

Finally, we test actual HTTP connectivity using `curl` and remove all temporary AWS resources.

**Workflow:**

Provision → Reproduce Failure → Analyze Network Path → Identify Root Cause → Remediate → Reanalyze → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-014 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, Reachability Analyzer, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Python |
| VPC CIDR | `10.140.0.0/16` |
| Public Subnet | `10.140.1.0/24` |
| Private Subnet | `10.140.2.0/24` |
| Source | Client EC2 |
| Destination | Server EC2 |
| Test Protocol | TCP |
| Destination Port | 8080 |
| Failure | Server security group missing inbound rule |
| Investigation Tool | VPC Reachability Analyzer |
| Remediation | Allow TCP 8080 from client SG |
| Verification | Reachability Analyzer and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company operates an application inside AWS.

The application has two components:

- A client EC2 instance in a public subnet.
- An internal application server in a private subnet.

The client must connect to the internal server using HTTP on TCP port 8080.

After a network security configuration change, the application begins timing out.

The cloud engineer verifies that both EC2 instances are running and the VPC has local routing between its subnets.

However, the HTTP connection cannot be established.

Using AWS Reachability Analyzer, the engineer discovers that the destination security group does not permit TCP 8080 from the client.

### Incident Symptoms

- Client EC2 is running.
- Server EC2 is running.
- Both instances belong to the same VPC.
- The VPC local route exists.
- Client security group permits outbound connections.
- Server security group has no inbound TCP 8080 rule.
- HTTP requests time out.
- Reachability Analyzer reports no reachable network path.
- Analysis identifies a security group configuration mismatch.

### Potential Business Impact

- Internal APIs become unavailable.
- Application requests time out.
- Microservice communication fails.
- Backend operations stop working.
- Application availability decreases.
- Troubleshooting requires additional engineering time.

### Incident Objective

Identify the AWS networking component blocking TCP 8080 and restore only the access necessary for the client to reach the server.

---

## 3. Architecture

### Healthy Architecture

```text
                        AWS Region: us-east-1
                                  |
                   +------------------------------+
                   | VPC: 10.140.0.0/16           |
                   |                              |
                   | Public Subnet                |
                   | 10.140.1.0/24                |
                   |                              |
                   | Client EC2                   |
                   | Client Security Group        |
                   |         |                    |
                   |         | TCP 8080           |
                   |         v                    |
                   | ---------------------------- |
                   |         |                    |
                   |         v                    |
                   | Private Subnet               |
                   | 10.140.2.0/24                |
                   |                              |
                   | Server Security Group        |
                   | Allows TCP 8080 from         |
                   | Client Security Group        |
                   |         |                    |
                   |         v                    |
                   | Server EC2                   |
                   | Python HTTP Server           |
                   +------------------------------+
                                  |
                                  v
                             HTTP 200 OK
```

### Broken Architecture

```text
Client EC2
    |
    | TCP 8080
    v
VPC Local Routing
    |
    v
Server Security Group
    |
    X
No Inbound TCP 8080 Rule
    |
    X
Connection Timeout
```

### Resources

| Component | Configuration |
|---|---|
| VPC | `10.140.0.0/16` |
| Client subnet | Public, `10.140.1.0/24` |
| Server subnet | Private, `10.140.2.0/24` |
| Client instance | Amazon Linux 2023 |
| Server instance | Amazon Linux 2023 |
| HTTP server | Python, TCP 8080 |
| Client SG | Default outbound access |
| Server SG | Initially no inbound access |
| Management | SSM on client |
| Analyzer source | Client EC2 instance |
| Analyzer destination | Server EC2 instance |

The client uses a public IP and Internet Gateway for Systems Manager access.

The server has no public IPv4 address.

Application communication uses private IPv4 addresses through the VPC-local route.

---

## 4. Understanding Reachability Analyzer

AWS VPC Reachability Analyzer is a network configuration analysis tool.

It evaluates whether a specified source resource can reach a destination resource using the requested protocol and port.

It can identify AWS network configuration problems involving:

- Security groups
- Network ACLs
- Route tables
- Network interfaces
- VPC connections
- Supported gateways and other network components

### How It Works

```text
Define Source
      |
      v
Define Destination
      |
      v
Specify Protocol and Port
      |
      v
Create Network Insights Path
      |
      v
Start Network Insights Analysis
      |
      v
Inspect Results
      |
      +--> NetworkPathFound = true
      |
      +--> NetworkPathFound = false
                  |
                  v
           Review Explanations
```

### Two Important Fields

**`Status`**

Indicates whether AWS completed the analysis successfully.

**`NetworkPathFound`**

Indicates whether the analyzer identified a valid network path.

Example:

```text
Status: succeeded
NetworkPathFound: false
```

This means the analysis completed, but the destination was not reachable through the evaluated configuration.

### Important Limitation

Reachability Analyzer does not send actual application packets.

It does not confirm that an HTTP server process is listening.

Therefore, we use `curl` after remediation to validate real application connectivity.

---

## 5. Prerequisites and Safety

### Required

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC permissions
- Reachability Analyzer permissions
- IAM permissions
- AWS Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated lab VPC.
- Do not modify production security groups.
- Keep the private server without a public IP.
- Do not open TCP 8080 to `0.0.0.0/0`.
- Reference the client security group for least-privilege access.
- Confirm resource ownership before cleanup.

### Costs

The lab creates:

- Two EC2 instances
- Two EBS root volumes
- One public IPv4 address
- One Network Insights Path
- Two Network Insights Analyses

Reachability Analyzer charges for analysis runs. EC2, EBS, public IPv4 usage, and applicable data transfer can also incur charges.

Perform only the planned analyses and clean up afterward.

---

## 6. Configure Environment Variables

Run all infrastructure commands in Ubuntu WSL2.

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab14"

export VPC_CIDR="10.140.0.0/16"
export PUBLIC_CIDR="10.140.1.0/24"
export PRIVATE_CIDR="10.140.2.0/24"

export VPC_NAME="cloud-lab14-vpc"

export ROLE_NAME="cloud-lab14-ssm-role"
export PROFILE_NAME="cloud-lab14-ssm-profile"

export LAB_AZ="us-east-1a"
```

Verify identity:

```bash
aws sts get-caller-identity
aws --version
```

Verify the selected Availability Zone supports `t3.micro`:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Check for existing Lab 14 resources:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create duplicates if resources already exist.

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
export PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab14-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet

```bash
export PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab14-private},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Configure Public IP Assignment

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"

aws ec2 modify-subnet-attribute \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --no-map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 6 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-lab14-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Create Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab14-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Add the Internet Gateway route:

```bash
aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Associate the public subnet:

```bash
export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

The private subnet uses the main route table with the VPC-local route.

### Verify Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected local routing:

```text
10.140.0.0/16 → local
```

---

## 8. Configure Security Groups

### Step 1 — Create Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-lab14-client-sg \
  --description "Lab14 client security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-lab14-client-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Server Security Group

```bash
export SERVER_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-lab14-server-sg \
  --description "Lab14 server security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-lab14-server-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Do not add an inbound TCP 8080 rule yet.

### Step 3 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" "$SERVER_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | Inbound | Outbound |
|---|---|---|
| Client SG | None | Default allow |
| Server SG | None | Default allow |

The missing server inbound rule is the intentional fault.

---

## 9. Configure IAM for the Client

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

### Step 2 — Check Existing IAM Resources

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For unused names, `NoSuchEntity` is expected.

### Step 3 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 4 — Attach Systems Manager Permissions

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 5 — Create Instance Profile

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

## 10. Prepare the HTTP Server

Create `server-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab14

cat > /opt/lab14/index.html <<'HTML'
AWS VPC Troubleshooting Lab 14

Service: Python HTTP Server
Port: 8080
Status: Application running
HTML

cat > /etc/systemd/system/lab14-http.service <<'UNIT'
[Unit]
Description=Lab 14 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab14
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab14-http.service
```

### Explanation

The script:

1. Creates a test web page.
2. Configures a Python HTTP server.
3. Listens on TCP port 8080.
4. Starts the application using systemd.
5. Enables automatic restart.

The server uses the Python standard library. No external package installation is required.

---

## 11. Launch EC2 Instances

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Lab Instances

```bash
aws ec2 describe-instances \
  --filters \
  "Name=tag:Project,Values=$PROJECT_TAG" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Launch Client EC2

```bash
export CLIENT_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$PUBLIC_SUBNET_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab14-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch Private Server EC2

```bash
export SERVER_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$PRIVATE_SUBNET_ID,Groups=$SERVER_SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://server-user-data.sh \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab14-server},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Wait for EC2 Health Checks

```bash
aws ec2 wait instance-running \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Record Private IPs

```bash
export CLIENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

export SERVER_IP=$(aws ec2 describe-instances \
  --instance-ids "$SERVER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "Client: $CLIENT_IP"
echo "Server: $SERVER_IP"
```

Expected:

```text
Client: 10.140.1.x
Server: 10.140.2.x
```

---

## 12. Reproduce the Connectivity Failure

### Step 1 — Verify Systems Manager Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$CLIENT_INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `Online`.

### Step 2 — Connect to Client

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Configure Server Private IP

Inside the client EC2:

```bash
export SERVER_IP="10.140.2.REPLACE"
```

Replace the placeholder with the actual server private IP.

### Step 4 — Test HTTP

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: connection timeout.

### Step 5 — Exit

```bash
exit
```

The timeout demonstrates the symptom but does not independently identify the underlying AWS networking component.

---

## 13. Create a Network Insights Path

### Step 1 — Create Path

From Ubuntu WSL2:

```bash
export PATH_ID=$(aws ec2 create-network-insights-path \
  --source "$CLIENT_INSTANCE_ID" \
  --destination "$SERVER_INSTANCE_ID" \
  --protocol tcp \
  --destination-port 8080 \
  --tag-specifications \
  "ResourceType=network-insights-path,Tags=[{Key=Name,Value=cloud-lab14-http-path},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Verify Path

```bash
aws ec2 describe-network-insights-paths \
  --network-insights-path-ids "$PATH_ID" \
  --query 'NetworkInsightsPaths[].{ID:NetworkInsightsPathId,Source:Source,Destination:Destination,Protocol:Protocol,Port:DestinationPort}' \
  --output json \
  --region "$AWS_REGION"
```

The path represents a TCP connection from the client EC2 to the server EC2 on port 8080.

---

## 14. Run the First Reachability Analysis

### Step 1 — Start Analysis

```bash
export FAILED_ANALYSIS_ID=$(aws ec2 start-network-insights-analysis \
  --network-insights-path-id "$PATH_ID" \
  --tag-specifications \
  "ResourceType=network-insights-analysis,Tags=[{Key=Name,Value=cloud-lab14-before-fix},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Status

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids "$FAILED_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[0].{Status:Status,PathFound:NetworkPathFound,Message:StatusMessage}' \
  --output json \
  --region "$AWS_REGION"
```

Repeat until the analysis finishes.

### Step 3 — Inspect Results

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids "$FAILED_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[0].{Status:Status,PathFound:NetworkPathFound,Explanations:Explanations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Status: succeeded
NetworkPathFound: false
```

### Expected Explanation

```text
ENI_SG_RULES_MISMATCH
```

This explanation means that security group rules associated with a network interface do not permit the analyzed traffic.

The actual explanation can contain additional details identifying the relevant network interface and security group.

### Step 4 — Examine Blocking Components

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids "$FAILED_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[0].Explanations[].{Code:ExplanationCode,Direction:Direction,SecurityGroups:SecurityGroups,NetworkInterface:NetworkInterface}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 5 — Inspect Server Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SERVER_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Investigation Summary

| Component | Finding |
|---|---|
| Client EC2 | Running |
| Server EC2 | Running |
| VPC routing | Local route available |
| Client outbound | Allowed |
| NACLs | Default rules permit traffic |
| Server inbound TCP 8080 | Missing |
| Analysis status | Succeeded |
| Network path found | False |
| Root cause | Server security group blocks TCP 8080 |

---

## 15. Root Cause Analysis

### Root Cause

The server security group did not contain an inbound rule allowing TCP 8080 from the client EC2 instance.

### Technical Explanation

The client attempts to establish a TCP connection with the private server.

The VPC contains a local route between the public and private subnets.

However, the destination security group evaluates the incoming connection and finds no rule allowing TCP 8080.

As a result, the connection is not permitted.

Reachability Analyzer evaluates the AWS network configuration and identifies the destination security group as a blocking component.

### Root Cause Flow

```text
Client EC2
    |
    v
TCP 8080 Request
    |
    v
VPC Local Route
    |
    v
Server Security Group
    |
    X
Inbound TCP 8080 Missing
    |
    X
No Reachable Network Path
```

### Five Whys

1. **Why did the HTTP connection fail?** The network security configuration did not permit TCP 8080.
2. **Why was TCP 8080 blocked?** The server security group lacked a matching inbound rule.
3. **Why was VPC routing not the problem?** Both subnets shared a valid local VPC route.
4. **Why was Reachability Analyzer useful?** It identified the AWS network component preventing reachability.
5. **How can this issue be prevented?** Manage security group rules through infrastructure as code and validate intended network paths after deployments.

---

## 16. Remediation

### Step 1 — Add Inbound TCP 8080

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify the Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SERVER_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: TCP
Port: 8080
Source: Client Security Group
```

### Why Use a Security Group Reference?

A source security group reference allows access from network interfaces associated with the referenced security group.

This provides more targeted access than permitting the whole VPC CIDR or the internet.

The private server does not need public inbound access.

---

## 17. Reanalyze the Network Path

### Step 1 — Run the Second Analysis

```bash
export SUCCESS_ANALYSIS_ID=$(aws ec2 start-network-insights-analysis \
  --network-insights-path-id "$PATH_ID" \
  --tag-specifications \
  "ResourceType=network-insights-analysis,Tags=[{Key=Name,Value=cloud-lab14-after-fix},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Results

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids "$SUCCESS_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[0].{Status:Status,PathFound:NetworkPathFound,Message:StatusMessage}' \
  --output json \
  --region "$AWS_REGION"
```

Repeat until analysis completes.

Expected:

```text
Status: succeeded
NetworkPathFound: true
```

### Step 3 — Inspect Network Path Components

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids "$SUCCESS_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[0].ForwardPathComponents[].{Sequence:SequenceNumber,Component:Component.Id}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Compare Results

```bash
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids \
  "$FAILED_ANALYSIS_ID" "$SUCCESS_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[].{ID:NetworkInsightsAnalysisId,Status:Status,Reachable:NetworkPathFound}' \
  --output table \
  --region "$AWS_REGION"
```

### Verification Matrix

| Component | Before Fix | After Fix |
|---|---|---|
| Client EC2 | Running | Running |
| Server EC2 | Running | Running |
| VPC local route | Present | Present |
| Server TCP 8080 inbound | Missing | Allowed |
| Analysis execution | Succeeded | Succeeded |
| `NetworkPathFound` | False | True |
| Network configuration | Blocked | Reachable |

---

## 18. Verify Actual HTTP Connectivity

A successful Reachability Analyzer result does not guarantee that an application is running.

We must test the actual HTTP service.

### Step 1 — Connect to Client

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Set the Server Address

Inside EC2:

```bash
export SERVER_IP="10.140.2.REPLACE"
```

Use the actual private IP.

### Step 3 — Test HTTP

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected response:

```text
AWS VPC Troubleshooting Lab 14

Service: Python HTTP Server
Port: 8080
Status: Application running
```

### Step 4 — Verify HTTP Status

```bash
curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'HTTP Status: %{http_code}\n' \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected:

```text
HTTP Status: 200
```

### If Reachability Analyzer Succeeds but curl Fails

Investigate:

- HTTP process not started
- Incorrect listening port
- Operating-system firewall
- Application startup errors
- Wrong destination IP
- Application configuration

Because the private server isn't SSM-managed in this lab, its boot logs and console output can provide useful application startup evidence.

From WSL, inspect its console output:

```bash
aws ec2 get-console-output \
  --instance-id "$SERVER_INSTANCE_ID" \
  --latest \
  --output text \
  --region "$AWS_REGION"
```

The output may contain cloud-init errors, although complete service logs aren't guaranteed to appear there.

---

## 19. Production Engineering Best Practices

### Reachability Analyzer Troubleshooting Checklist

1. Confirm the source and destination resources.
2. Identify the relevant protocol and destination port.
3. Check the instance and network interface states.
4. Verify the source subnet route table.
5. Verify the destination subnet route table.
6. Inspect source security group outbound rules.
7. Inspect destination security group inbound rules.
8. Inspect relevant network ACLs.
9. Create a Network Insights Path.
10. Run Reachability Analyzer.
11. Review `NetworkPathFound`.
12. Inspect explanation codes and blocking components.
13. Apply the least-privilege remediation.
14. Reanalyze the same path.
15. Verify real application connectivity.

### Common Explanation Codes

| Explanation Code | Meaning |
|---|---|
| `ENI_SG_RULES_MISMATCH` | Security group rules do not permit the traffic |
| `SG_HAS_NO_RULES` | Relevant security group lacks applicable rules |
| `NO_ROUTE_TO_DESTINATION` | No applicable route to destination |
| `BAD_STATE_ROUTE` | Route is not in a functional state |
| `DISCONNECTED_VPCS` | VPCs are not connected by a supported resource |
| `NO_PATH` | No valid matching network path identified |

Explanation codes can vary based on the evaluated resources and configuration.

### Prevention

- Use Terraform for security groups and route tables.
- Apply least-privilege rules.
- Review networking changes through GitHub pull requests.
- Test intended traffic paths during deployments.
- Separate network reachability tests from application health tests.
- Avoid opening private services to the internet.
- Monitor AWS networking changes through CloudTrail.
- Use Reachability Analyzer when investigating complex network paths.

---

## 20. Interview Questions and Answers

### Q1. What is AWS VPC Reachability Analyzer?

It is an AWS network configuration analysis tool used to determine whether a specified source can reach a destination.

### Q2. Does Reachability Analyzer send real network packets?

No. It analyzes AWS networking configurations rather than performing an application-level packet test.

### Q3. What is a Network Insights Path?

A definition of a source, destination, protocol, and optional traffic constraints that Reachability Analyzer evaluates.

### Q4. What does `NetworkPathFound=false` indicate?

The analyzer did not identify a permitted path for the specified traffic.

### Q5. What does `ENI_SG_RULES_MISMATCH` mean?

The relevant security group rules do not permit the analyzed traffic.

### Q6. Does `Status=succeeded` mean traffic is reachable?

No. It only confirms that the analysis completed. Reachability is shown through `NetworkPathFound`.

### Q7. Can Reachability Analyzer troubleshoot route table issues?

Yes. It can identify supported routing problems that prevent traffic from reaching its destination.

### Q8. Can Reachability Analyzer troubleshoot security groups?

Yes. It can identify security group rules that prevent connectivity.

### Q9. Can `NetworkPathFound=true` occur when an application is down?

Yes. The AWS network configuration can permit traffic even when no application is listening on the destination port.

### Q10. Why did this lab use curl after the analysis?

To confirm that the real HTTP server responded successfully.

### Q11. How is Reachability Analyzer different from VPC Flow Logs?

Reachability Analyzer evaluates network configuration. VPC Flow Logs records metadata about observed network traffic.

### Q12. How would you explain this lab in an interview?

I deployed two EC2 instances in separate subnets of the same AWS VPC and configured a Python HTTP server on TCP port 8080. The client initially could not reach the server because the destination security group had no matching inbound rule.

I used AWS Reachability Analyzer to investigate the network path. The analysis showed that the path was not reachable and identified the relevant security group restriction.

I restored least-privilege inbound access from the client security group, ran another analysis, and verified that the network path was reachable. Finally, I tested the application using curl and confirmed HTTP 200.

---

## 21. Cleanup

**Warning:** The following commands delete lab resources. Verify account identity, resource IDs, and ownership tags before running them.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Verify Network Insights Resources

```bash
aws ec2 describe-network-insights-paths \
  --network-insights-path-ids "$PATH_ID" \
  --query 'NetworkInsightsPaths[].{ID:NetworkInsightsPathId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids \
  "$FAILED_ANALYSIS_ID" "$SUCCESS_ANALYSIS_ID" \
  --query 'NetworkInsightsAnalyses[].{ID:NetworkInsightsAnalysisId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 3 — Delete Analyses

```bash
aws ec2 delete-network-insights-analysis \
  --network-insights-analysis-id "$FAILED_ANALYSIS_ID" \
  --region "$AWS_REGION"

aws ec2 delete-network-insights-analysis \
  --network-insights-analysis-id "$SUCCESS_ANALYSIS_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Network Insights Path

```bash
aws ec2 delete-network-insights-path \
  --network-insights-path-id "$PATH_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Record EBS Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Volumes:BlockDeviceMappings[].Ebs}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm root volumes have `DeleteOnTermination=true`.

### Step 6 — Terminate EC2 Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Remove Security Group Reference

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

Skip this command if the rule is already absent.

### Step 8 — Verify Network Interfaces Are Removed

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Proceed after the lab ENIs are removed.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$SERVER_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete IAM Resources

Verify role ownership and instance profile usage:

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Delete:

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 11 — Delete Public Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete VPC

Confirm no unexpected dependencies remain.

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify Cleanup

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

Also verify the Network Insights resources, VPC, and root EBS volumes are gone.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Failed-path analysis | Deleted |
| Successful-path analysis | Deleted |
| Network Insights Path | Deleted |
| Client EC2 | Terminated |
| Server EC2 | Terminated |
| Root EBS volumes | Deleted |
| Client SG | Deleted |
| Server SG | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Public route table | Deleted |
| Public subnet | Deleted |
| Private subnet | Deleted |
| Internet Gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 22. Repository Structure

```text
14-reachability-analyzer-investigation/
├── README.md
├── ec2-trust-policy.json
└── server-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident procedure and documentation |
| `ec2-trust-policy.json` | EC2 IAM role trust policy |
| `server-user-data.sh` | Configures the private Python HTTP server |

Do not commit AWS access keys, credentials, or other private information.

---

## 23. Lessons Learned

This lab demonstrates how AWS Reachability Analyzer can help identify network configuration problems without requiring packet-level troubleshooting.

Initially, both EC2 instances were running, and the VPC had valid local routing.

However, the destination security group did not permit TCP 8080 from the client.

Reachability Analyzer identified that the configured network path was not reachable.

After restoring the required inbound security group rule, the analyzer reported a reachable path.

Testing with curl provided separate confirmation that the HTTP application was accessible.

**Key Lesson:** Reachability Analyzer helps identify AWS network configuration problems, but successful application connectivity should still be verified using a real network test.

---

## 24. Skills Demonstrated

- AWS VPC Reachability Analyzer
- Network Insights Path creation
- Network Insights Analysis investigation
- Security group troubleshooting
- EC2-to-EC2 connectivity
- Public and private subnet networking
- AWS local routing
- AWS CLI v2
- Systems Manager administration
- Linux HTTP testing
- Root cause analysis
- Least-privilege security remediation
- Network verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-014 |
| Problem | EC2 HTTP connectivity failure |
| Root Cause | Missing server inbound TCP 8080 rule |
| Initial Network Path | Not reachable |
| Explanation | Security group rules mismatch |
| Remediation | Allow TCP 8080 from client SG |
| Network Path After Fix | Reachable |
| HTTP After Fix | 200 OK |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** AWS Reachability Analyzer provides a structured way to identify and remediate AWS network configuration failures. Use it together with application-level testing to confirm complete connectivity.
