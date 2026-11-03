# Lab 12 — Overlapping VPC CIDR Blocks

## Overview

This lab demonstrates how to troubleshoot an AWS VPC peering failure caused by overlapping IPv4 CIDR blocks.

We create two separate VPCs with conflicting IP address ranges and attempt to establish a VPC peering connection.

Although AWS allows these VPCs to exist independently, VPC peering cannot be established between them because their address ranges overlap.

We investigate the failure using AWS CLI and Python, identify the conflicting CIDR blocks, and create a replacement VPC with a non-overlapping IP range.

After correcting the addressing plan, we successfully establish VPC peering and configure routes between the two VPCs.

**Troubleshooting workflow:**

Provision → Reproduce Failure → Investigate → Root Cause Analysis → Correct CIDR Plan → Establish Peering → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-012 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, VPC Peering, Route Tables |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, Python |
| VPC A CIDR | `10.130.0.0/16` |
| VPC B CIDR | `10.130.128.0/17` |
| Replacement VPC C | `10.140.0.0/16` |
| Simulated Failure | Overlapping CIDR blocks |
| Root Cause | Conflicting IP address allocation |
| Remediation | Create a VPC using a non-overlapping CIDR |
| Verification | Active peering connection and valid routes |
| EC2 Instances | Not required |
| NAT Gateway | Not required |
| Internet Gateway | Not required |

---

## 2. Production Incident Scenario

### Incident Description

A company operates two AWS VPCs managed by different engineering teams.

VPC A hosts the company's application infrastructure, while VPC B hosts another department's services.

The networking team needs to connect both VPCs using VPC peering so that applications can communicate privately.

However, the peering request fails.

The engineer investigates and finds:

- Both VPCs exist.
- Both VPCs are in the same AWS Region.
- VPC A uses `10.130.0.0/16`.
- VPC B uses `10.130.128.0/17`.
- VPC B's CIDR range is contained within VPC A's range.
- AWS does not allow peering between overlapping VPC CIDR blocks.
- Changing route tables cannot solve this problem.

### Business Impact

- Applications cannot establish direct VPC peering connectivity.
- Cross-VPC service integration is delayed.
- Network migrations may require redesign.
- Infrastructure deployment can fail.
- Engineering teams must coordinate IP address allocation.
- Address conflicts create future network expansion problems.

### Incident Objective

Identify overlapping CIDR ranges and redesign the VPC addressing plan so that a valid peering connection can be established.

---

## 3. AWS Architecture

### Broken Architecture

```text
              AWS Region: us-east-1

+-----------------------+    +-----------------------+
| VPC A                 |    | VPC B                 |
|                       |    |                       |
| 10.130.0.0/16         |    | 10.130.128.0/17       |
|                       |    |                       |
| IP Range:             |    | IP Range:             |
| 10.130.0.0            |    | 10.130.128.0          |
|       to              |    |       to              |
| 10.130.255.255        |    | 10.130.255.255        |
+-----------+-----------+    +-----------+-----------+
            |                            |
            +-------------X--------------+
                          |
                 VPC Peering Failed
                          |
                  Overlapping CIDRs
```

### Corrected Architecture

```text
              AWS Region: us-east-1

+-----------------------+    +-----------------------+
| VPC A                 |    | VPC C                 |
|                       |    |                       |
| 10.130.0.0/16         |    | 10.140.0.0/16         |
|                       |    |                       |
| Route Table A         |    | Route Table C         |
|                       |    |                       |
| 10.140.0.0/16         |    | 10.130.0.0/16         |
|      -> Peering       |    |      -> Peering       |
+-----------+-----------+    +-----------+-----------+
            |                            |
            +------ VPC Peering ---------+
                       Active
```

### CIDR Allocation

| VPC | CIDR | Address Range | Status |
|---|---|---|---|
| VPC A | `10.130.0.0/16` | `10.130.0.0–10.130.255.255` | Original |
| VPC B | `10.130.128.0/17` | `10.130.128.0–10.130.255.255` | Overlapping |
| VPC C | `10.140.0.0/16` | `10.140.0.0–10.140.255.255` | Corrected |

VPC B's entire CIDR falls inside VPC A's CIDR.

Replacing VPC B with VPC C eliminates the address conflict.

---

## 4. Understanding CIDR Overlap

CIDR stands for Classless Inter-Domain Routing.

CIDR notation defines an IP network and the size of its address range.

### Example 1 — VPC A

```text
Network: 10.130.0.0/16

Range:
10.130.0.0
     to
10.130.255.255
```

A `/16` IPv4 network contains 65,536 total addresses.

### Example 2 — VPC B

```text
Network: 10.130.128.0/17

Range:
10.130.128.0
     to
10.130.255.255
```

A `/17` IPv4 network contains 32,768 total addresses.

### Why They Overlap

The `/17` range is completely included within the `/16` range.

Therefore, the two networks share IP addresses.

### Non-Overlapping Example

```text
VPC A: 10.130.0.0/16
VPC C: 10.140.0.0/16
```

These ranges do not share any IP addresses.

### Important AWS Rules

1. AWS permits separate VPCs to have overlapping CIDRs.
2. VPC peering does not support overlapping IPv4 or IPv6 CIDR ranges.
3. Every associated VPC CIDR block must be considered, including secondary CIDRs.
4. Route table changes cannot bypass the peering CIDR restriction.
5. A VPC's primary IPv4 CIDR cannot simply be replaced with a completely different range.
6. Production remediation may require workload migration to a correctly addressed VPC.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Python 3
- VPC management permissions
- Git and GitHub

### Safety Requirements

- Use dedicated lab VPCs.
- Do not modify production CIDR allocations.
- Do not modify the default VPC.
- Verify account identity before provisioning.
- Check for existing resources.
- Do not delete unrelated peering connections.
- Verify resource tags before cleanup.

### Cost Considerations

This lab does not require EC2, NAT Gateways, or interface endpoints.

Creating VPCs, route tables, and VPC peering connections generally does not incur hourly resource charges.

No application data transfer is performed.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab12"

export VPC_A_NAME="cloud-lab12-vpc-a"
export VPC_B_NAME="cloud-lab12-vpc-b-overlap"
export VPC_C_NAME="cloud-lab12-vpc-c-corrected"

export VPC_A_CIDR="10.130.0.0/16"
export VPC_B_CIDR="10.130.128.0/17"
export VPC_C_CIDR="10.140.0.0/16"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Check Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

If previous Lab 12 VPCs exist, inspect them before creating duplicates.

---

## 7. Detect CIDR Overlap Using Python

Before provisioning the infrastructure, validate the network ranges.

### Step 1 — Run Python CIDR Validation

```bash
python3 - <<'PY'
import ipaddress

vpc_a = ipaddress.ip_network("10.130.0.0/16")
vpc_b = ipaddress.ip_network("10.130.128.0/17")
vpc_c = ipaddress.ip_network("10.140.0.0/16")

print("A and B overlap:", vpc_a.overlaps(vpc_b))
print("A and C overlap:", vpc_a.overlaps(vpc_c))
print("B and C overlap:", vpc_b.overlaps(vpc_c))
PY
```

### Expected Results

```text
A and B overlap: True
A and C overlap: False
B and C overlap: False
```

### Explanation

Python's `ipaddress` module can detect whether two networks share address space.

The `overlaps()` method returns `True` when networks have at least one address in common.

This is useful for validating CIDR plans before deploying infrastructure.

---

## 8. Create the Conflicting VPCs

### Step 1 — Create VPC A

```bash
export VPC_A_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_A_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_A_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_A_ID"
```

### Step 2 — Create VPC B

```bash
export VPC_B_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_B_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_B_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_B_ID"
```

### Step 3 — Verify Both VPCs

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_B_ID" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

### Expected Behavior

Both VPCs are successfully created.

AWS allows overlapping CIDRs in independent VPCs.

The restriction applies when attempting to peer the networks.

---

## 9. Reproduce the VPC Peering Failure

### Step 1 — Attempt Peering

```bash
export FAILED_PCX_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "$VPC_A_ID" \
  --peer-vpc-id "$VPC_B_ID" \
  --tag-specifications \
  "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cloud-lab12-overlap-failed},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
  --output text \
  --region "$AWS_REGION")

echo "$FAILED_PCX_ID"
```

### Step 2 — Inspect Peering Status

If AWS returned a peering connection ID:

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$FAILED_PCX_ID" \
  --query 'VpcPeeringConnections[0].{ID:VpcPeeringConnectionId,Status:Status.Code,Message:Status.Message}' \
  --output json \
  --region "$AWS_REGION"
```

### Expected Result

The peering request fails because the VPC CIDRs overlap.

AWS may return a peering connection with status `failed`, or the command may report an error. Capture the actual result.

Example conceptual result:

```text
Peering Status: failed
Reason: Overlapping CIDR blocks
```

### Step 3 — Verify the Peering Is Not Active

```bash
aws ec2 describe-vpc-peering-connections \
  --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_A_ID" \
  --query 'VpcPeeringConnections[].{ID:VpcPeeringConnectionId,Status:Status.Code,Message:Status.Message}' \
  --output table \
  --region "$AWS_REGION"
```

The conflicting peering connection should not report `active`.

### Failure Summary

| Component | Finding |
|---|---|
| VPC A | Available |
| VPC B | Available |
| AWS Region | Same |
| VPC A CIDR | `10.130.0.0/16` |
| VPC B CIDR | `10.130.128.0/17` |
| Overlap | Yes |
| Peering | Failed |
| Root cause | Conflicting address ranges |

---

## 10. Troubleshooting Investigation

### Check 1 — Inspect Complete VPC CIDR Associations

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_B_ID" \
  --query 'Vpcs[].{ID:VpcId,CIDRs:CidrBlockAssociationSet[].CidrBlock}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 2 — Verify CIDR Overlap

```bash
python3 - <<'PY'
import ipaddress

a = ipaddress.ip_network("10.130.0.0/16")
b = ipaddress.ip_network("10.130.128.0/17")

print("VPC A:", a)
print("VPC B:", b)
print("Overlap:", a.overlaps(b))
print("VPC B inside VPC A:", b.subnet_of(a))
PY
```

Expected:

```text
VPC A: 10.130.0.0/16
VPC B: 10.130.128.0/17
Overlap: True
VPC B inside VPC A: True
```

### Check 3 — Inspect Peering Failure

```bash
aws ec2 describe-vpc-peering-connections \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'VpcPeeringConnections[].{ID:VpcPeeringConnectionId,Status:Status.Code,Message:Status.Message}' \
  --output table \
  --region "$AWS_REGION"
```

Failed peering records may become unavailable after AWS's retention period.

### Investigation Summary

| Component | Finding |
|---|---|
| VPC A CIDR | Correct for VPC A |
| VPC B CIDR | Conflicts with VPC A |
| Secondary CIDRs | Must also be inspected |
| Peering status | Failed |
| Security groups | Not responsible |
| Route tables | Not responsible |
| Root cause | Overlapping CIDR allocation |

---

## 11. Root Cause Analysis

### Root Cause

VPC A and VPC B were assigned overlapping private IPv4 address ranges.

### Technical Explanation

VPC A uses:

```text
10.130.0.0/16
```

VPC B uses:

```text
10.130.128.0/17
```

The address range assigned to VPC B is completely contained within VPC A's CIDR range.

AWS VPC peering does not support overlapping address ranges.

Therefore, a valid peering connection cannot be established.

### Root Cause Flow

```text
VPC A: 10.130.0.0/16
          |
          v
VPC B: 10.130.128.0/17
          |
          v
CIDR Overlap Detected
          |
          X
VPC Peering Fails
```

### Five Whys

1. **Why did VPC peering fail?** The VPCs contain overlapping address ranges.
2. **Why does AWS reject overlapping CIDRs?** Peering requires non-overlapping address spaces for supported routing.
3. **Why were overlapping networks created?** IP allocation was not coordinated between teams.
4. **Why couldn't route table changes fix the problem?** The peering connection could not become active.
5. **How can the issue be prevented?** Use centralized IP address planning, AWS VPC IPAM, and automated CIDR validation.

---

## 12. Remediation

### Step 1 — Create a Replacement VPC

For this lab, create VPC C with a non-overlapping CIDR.

```bash
export VPC_C_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_C_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_C_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_C_ID"
```

### Step 2 — Verify VPC Addressing

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_C_ID" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
VPC A: 10.130.0.0/16
VPC C: 10.140.0.0/16
```

### Step 3 — Create the Corrected Peering Connection

```bash
export PCX_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "$VPC_A_ID" \
  --peer-vpc-id "$VPC_C_ID" \
  --tag-specifications \
  "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cloud-lab12-peering-corrected},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Accept Peering

```bash
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Peering Status

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
active
```

The new peering request succeeds because VPC A and VPC C have non-overlapping CIDRs.

---

## 13. Configure Peering Routes

### Step 1 — Create Route Table A

```bash
export RT_A_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_A_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab12-rt-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Route Table C

```bash
export RT_C_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_C_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab12-rt-c},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Route from VPC A to VPC C

```bash
aws ec2 create-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_C_CIDR" \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create Return Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_C_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" "$RT_C_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Route Table | Destination | Target |
|---|---|---|
| Route Table A | `10.130.0.0/16` | Local |
| Route Table A | `10.140.0.0/16` | Peering |
| Route Table C | `10.140.0.0/16` | Local |
| Route Table C | `10.130.0.0/16` | Peering |

These custom route tables are not associated with subnets because this lab does not deploy workloads.

The verification confirms that the corrected peering and route configurations exist. It does not demonstrate application connectivity.

---

## 14. Verification

### Step 1 — Verify Corrected Peering

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].{ID:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Status: active
Requester: 10.130.0.0/16
Accepter: 10.140.0.0/16
```

### Step 2 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" "$RT_C_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the peer routes are active and reference the corrected peering connection.

### Verification Matrix

| Check | Broken | Corrected |
|---|---|---|
| VPC A CIDR | `10.130.0.0/16` | `10.130.0.0/16` |
| Peer CIDR | `10.130.128.0/17` | `10.140.0.0/16` |
| CIDR overlap | Yes | No |
| Peering connection | Failed | Active |
| Route A to peer | Not configured | Configured |
| Peer return route | Not configured | Configured |
| EC2 connectivity | Not tested | Not tested |
| Network design | Invalid for peering | Valid for peering |

### Success Criteria

- Overlapping CIDRs are identified.
- The initial peering request is confirmed unsuccessful.
- The corrected VPC uses non-overlapping addressing.
- The replacement peering connection becomes active.
- Both custom route tables contain valid peer routes.
- Lab resources are safely deleted.

---

## 15. Production Best Practices

### CIDR Planning Checklist

1. List all existing VPC CIDRs.
2. Check primary and secondary CIDR blocks.
3. Check on-premises networks.
4. Check VPN and Direct Connect address ranges.
5. Check connected VPCs and transit gateway routing domains.
6. Detect overlapping networks before provisioning.
7. Reserve address ranges for future growth.
8. Maintain centralized network documentation.
9. Use infrastructure-as-code validation.
10. Review address allocation changes before deployment.

### Preventing CIDR Conflicts

- Use AWS VPC IP Address Manager (IPAM).
- Allocate CIDRs centrally.
- Validate CIDR overlap using Python.
- Maintain unique ranges across networks that must communicate.
- Review VPC architecture before peering.
- Manage infrastructure with Terraform.
- Use GitHub pull requests for networking changes.

### Production Remediation Options

When overlapping networks already host workloads, possible approaches include:

- Migrate workloads into a replacement VPC.
- Redesign the overall IP address allocation.
- Use service-level connectivity mechanisms with appropriate address translation or proxies where suitable.
- Assess AWS PrivateLink for supported service-to-service access patterns.

These alternatives do not remove the CIDR overlap restriction for standard VPC peering.

---

## 16. Interview Questions and Answers

### Q1. What is an overlapping CIDR?

Two network address ranges that share one or more IP addresses.

### Q2. Can AWS create two VPCs with overlapping CIDRs?

Yes. Separate VPCs can use overlapping address spaces.

### Q3. Can these VPCs establish VPC peering?

No. AWS VPC peering does not support overlapping VPC CIDR blocks.

### Q4. Why did peering fail in this lab?

VPC B's `10.130.128.0/17` range was contained within VPC A's `10.130.0.0/16` range.

### Q5. Can route table changes resolve overlapping CIDRs?

No. The address conflict must be corrected first.

### Q6. Can you change the primary IPv4 CIDR of an existing VPC?

You cannot directly replace the primary IPv4 CIDR with a different block.

### Q7. What happens if only secondary CIDRs overlap?

The overlap can still prevent VPC peering.

### Q8. What tool can detect overlapping CIDRs?

Python's `ipaddress` module can identify overlapping networks. AWS VPC IPAM can also help manage address allocations.

### Q9. Does an active peering connection automatically enable communication?

No. Routes, security groups, NACLs, and workload configurations must also be correct.

### Q10. What is AWS VPC IPAM?

AWS VPC IP Address Manager helps organizations plan, track, and manage IP address allocations across AWS environments.

### Q11. How is Lab 12 different from Lab 11?

Lab 11 investigates a missing return route in an active VPC peering connection. Lab 12 investigates a CIDR conflict that prevents successful peering.

### Q12. How would you explain this lab in an interview?

> I created two AWS VPCs with overlapping CIDR blocks and attempted to establish VPC peering. The peering request failed because their address ranges overlapped. I investigated the VPC CIDR associations using AWS CLI and confirmed the overlap using Python's ipaddress module. I then created a replacement VPC with a non-overlapping CIDR, established a new peering connection, and configured bidirectional routes. The lab demonstrated the importance of IP address planning in multi-VPC AWS environments.

---

## 17. Cleanup

**Important:** Verify that all resources belong to `VPC-Troubleshooting-Lab12` before deleting anything.

### Step 1 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify VPC Ownership

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_B_ID" "$VPC_C_ID" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the `Project` tag for each VPC.

### Step 3 — Delete Peering Routes

```bash
aws ec2 delete-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_C_CIDR" \
  --region "$AWS_REGION"

aws ec2 delete-route \
  --route-table-id "$RT_C_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

### Step 4 — Delete the Successful Peering Connection

```bash
aws ec2 delete-vpc-peering-connection \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Inspect Failed Peering Record

If the failed peering request returned an ID:

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$FAILED_PCX_ID" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text \
  --region "$AWS_REGION"
```

Failed peering records may remain temporarily visible. If AWS no longer returns the record, no further action is required. Do not attempt to force deletion of a record that AWS does not permit deleting in its current state.

### Step 6 — Delete Custom Route Tables

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_C_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify Network Dependencies

```bash
for VPC_ID in "$VPC_A_ID" "$VPC_B_ID" "$VPC_C_ID"; do

  aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output table \
    --region "$AWS_REGION"

done
```

Confirm there are no unexpected resources depending on these VPCs.

### Step 8 — Delete VPCs

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_C_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify Cleanup

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no Lab 12 VPCs.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| VPC A | Deleted |
| VPC B | Deleted |
| VPC C | Deleted |
| Failed peering request | Failed/inactive; AWS-managed retention |
| Corrected peering connection | Deleted |
| Route Table A | Deleted |
| Route Table C | Deleted |
| Default VPC | Unchanged |

---

## 18. Repository Structure

```text
12-overlapping-vpc-cidr-blocks/
└── README.md
```

Only one file is required for this lab because the entire exercise uses AWS CLI and a short Python CIDR validation command.

No EC2 instances, IAM trust policies, or user-data scripts are needed.

---

## 19. Lessons Learned

This lab demonstrates why IP address planning is important when designing multi-VPC AWS environments.

AWS permits independent VPCs to use overlapping CIDR ranges, but those VPCs cannot establish standard VPC peering.

In this scenario, VPC B's address space was contained within VPC A's range, causing the peering request to fail.

The failure could not be resolved through route table or security group changes.

Creating a replacement VPC with a non-overlapping CIDR allowed a new peering connection to become active.

The exercise also demonstrated how Python can detect address conflicts before resources are deployed.

**Key Lesson:** Always validate primary and secondary VPC CIDR blocks before establishing VPC peering. Correct IP address planning prevents connectivity failures and costly network redesigns.

---

## 20. Skills Demonstrated

- AWS VPC networking
- IPv4 addressing and CIDR notation
- CIDR overlap detection
- VPC peering troubleshooting
- AWS CLI v2
- Python `ipaddress` module
- Route table configuration
- Network address planning
- Root cause analysis
- Infrastructure fault simulation
- Multi-VPC architecture
- Network remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-012 |
| Problem | VPC peering fails |
| Root Cause | Overlapping CIDR ranges |
| VPC A | `10.130.0.0/16` |
| Conflicting VPC B | `10.130.128.0/17` |
| Replacement VPC C | `10.140.0.0/16` |
| Initial Peering | Failed |
| Corrected Peering | Active |
| Bidirectional Routes | Configured |
| Application Connectivity | Not tested |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** AWS VPC peering requires non-overlapping address ranges. When CIDRs overlap, the solution is to correct the network addressing design, not modify routes or security groups.
