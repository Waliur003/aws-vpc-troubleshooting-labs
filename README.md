# AWS VPC Troubleshooting Labs

### 15 Hands-On AWS Networking and Security Troubleshooting Labs

A practical, production-style AWS VPC troubleshooting repository designed to develop real-world Cloud Engineering, Cloud Operations, and Cloud Security Engineering skills.

This repository contains 15 hands-on labs that simulate common AWS networking problems, demonstrate systematic diagnosis, and provide step-by-step remediation using AWS CLI, Linux, and AWS networking tools.

Each lab follows a realistic incident response workflow:

**Deploy → Verify → Simulate Failure → Investigate → Identify Root Cause → Remediate → Verify Recovery → Cleanup**

---

## Objectives

The goals of this repository are to:

- Understand Amazon VPC networking from basic to advanced.
- Troubleshoot subnet, route table, and internet connectivity problems.
- Investigate security group and network ACL misconfigurations.
- Diagnose NAT gateway, VPC endpoint, and DNS issues.
- Learn VPC Flow Logs and Reachability Analyzer.
- Apply least-privilege and network isolation principles.
- Practice production incident investigation and remediation.
- Build practical networking skills for AWS Cloud and Cloud Security Engineer roles.

---

## AWS Services and Tools

| Category | Technologies |
|---|---|
| Cloud Platform | Amazon Web Services |
| Networking | VPC, Subnets, Route Tables, IGW, NAT Gateway |
| Security | Security Groups, Network ACLs |
| Connectivity | VPC Peering, VPC Endpoints |
| DNS | Route 53 Resolver, VPC DNS |
| Monitoring | VPC Flow Logs, CloudWatch Logs |
| Network Analysis | VPC Reachability Analyzer |
| Compute | Amazon EC2 |
| Command Line | AWS CLI v2, Bash |
| Operating Systems | Linux, Ubuntu WSL2 |
| Version Control | Git, GitHub |

---

## Troubleshooting Labs

The labs progress from basic VPC networking issues to more advanced production-style troubleshooting.

| Lab | Folder | Incident Scenario | Difficulty |
|---|---|---|---|
| 01 | [VPC CIDR Configuration Error](./01-vpc-cidr-configuration-error/) | Invalid or overlapping network address ranges | Beginner |
| 02 | [Subnet Creation Failure](./02-subnet-creation-failure/) | Invalid subnet CIDR, overlapping subnets, or exhausted address space | Beginner |
| 03 | [Public Subnet Cannot Access Internet](./03-public-subnet-no-internet/) | Missing internet gateway route | Beginner |
| 04 | [Private Subnet Cannot Access Internet](./04-private-subnet-no-internet/) | Private subnet missing a valid egress path | Intermediate |
| 05 | [Route Table Misconfiguration](./05-route-table-misconfiguration/) | Incorrect route table association or destination route | Intermediate |
| 06 | [Security Group Blocks Traffic](./06-security-group-blocks-traffic/) | Inbound or outbound security group rule issue | Intermediate |
| 07 | [Network ACL Blocks Traffic](./07-network-acl-blocks-traffic/) | Stateless NACL rules block required traffic | Intermediate |
| 08 | [NAT Gateway Connection Failure](./08-nat-gateway-connection-failure/) | Incorrect NAT gateway routes or configuration | Intermediate |
| 09 | [VPC DNS Resolution Failure](./09-vpc-dns-resolution-failure/) | VPC DNS support or DHCP options misconfiguration | Intermediate |
| 10 | [VPC Endpoint Connection Failure](./10-vpc-endpoint-connection-failure/) | Endpoint routing, policy, DNS, or security group issue | Intermediate |
| 11 | [VPC Peering Connection Failure](./11-vpc-peering-connection-failure/) | Missing peering routes or restrictive security rules | Advanced |
| 12 | [VPC Flow Logs Investigation](./12-vpc-flow-logs-investigation/) | Analyze rejected or unexpected network traffic | Advanced |
| 13 | [Reachability Analyzer Troubleshooting](./13-reachability-analyzer-troubleshooting/) | Identify a blocking component in a network path | Advanced |
| 14 | [Interface Endpoint Private DNS Failure](./14-interface-endpoint-private-dns-failure/) | Private DNS or endpoint security group misconfiguration | Advanced |
| 15 | [Multi-Tier VPC Connectivity Failure](./15-multi-tier-vpc-connectivity-failure/) | Diagnose multi-layer communication failures between application tiers | Advanced |

Each lab receives its own detailed `README.md` covering investigation, commands, expected observations, root cause, remediation, verification, and cleanup.

---

## Reference Architecture

The repository progressively introduces the components of a typical AWS VPC environment.

```text
                        Internet
                            |
                            v
                    Internet Gateway
                            |
               +------------+------------+
               |                         |
               v                         v
         Public Subnet              Public Subnet
               |                         |
               v                         v
           EC2 / ALB                NAT Gateway
                                         |
                                         v
                                   Private Subnet
                                         |
                               +---------+---------+
                               |                   |
                               v                   v
                          Application          VPC Endpoint
                           Instances                 |
                               |                     v
                               v                 AWS Services
                          Internal Services

          Security Groups + Network ACLs + Route Tables
                             |
                             v
                 VPC Flow Logs and Analysis
```

This is a conceptual reference architecture. Individual labs use smaller, isolated environments suited to their troubleshooting objectives.

---

## Troubleshooting Methodology

Every lab uses a consistent operational approach.

### 1. Establish a Healthy Baseline

Deploy or identify a working environment.

Verify expected routing, security rules, and connectivity before introducing a fault.

### 2. Reproduce the Failure

Introduce one controlled misconfiguration, or perform a safe validation test for failures that cannot be reproduced reliably.

### 3. Investigate

Collect relevant evidence using AWS CLI, Linux networking commands, CloudWatch, VPC Flow Logs, or Reachability Analyzer.

### 4. Identify the Root Cause

Determine which networking component prevents the expected communication.

### 5. Apply Remediation

Correct only the affected configuration while preserving unrelated resources.

### 6. Verify Recovery

Repeat the original connectivity test and confirm that the intended communication path works.

### 7. Clean Up Resources

Remove disposable AWS resources and verify that shared VPC resources remain unchanged.

---

## Example Troubleshooting Commands

### Inspect VPCs

```bash
aws ec2 describe-vpcs \
  --region us-east-1
```

### Inspect Subnets

```bash
aws ec2 describe-subnets \
  --region us-east-1
```

### Inspect Route Tables

```bash
aws ec2 describe-route-tables \
  --region us-east-1
```

### Inspect Security Groups

```bash
aws ec2 describe-security-groups \
  --region us-east-1
```

### Inspect Network ACLs

```bash
aws ec2 describe-network-acls \
  --region us-east-1
```

### Inspect Internet Gateways

```bash
aws ec2 describe-internet-gateways \
  --region us-east-1
```

### Inspect NAT Gateways

```bash
aws ec2 describe-nat-gateways \
  --region us-east-1
```

### Inspect VPC Endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --region us-east-1
```

These commands help establish an initial network configuration inventory.

---

## Production Incident Documentation

Each lab includes:

1. Incident overview and business impact
2. Architecture and technical explanation
3. Prerequisites and safety considerations
4. AWS environment setup
5. Baseline verification
6. Controlled failure simulation
7. Troubleshooting investigation
8. Root cause analysis
9. Step-by-step remediation
10. Recovery verification
11. Production best practices
12. Cleanup instructions
13. Interview questions and answers

The goal is to understand not only how to fix a networking problem, but also why it happens and how to prevent it.

---

## Cost and Safety Guidelines

Some AWS networking components generate charges even when there is little or no traffic.

Particular care is required with:

- NAT gateways
- Interface VPC endpoints
- Public IPv4 addresses
- EC2 instances
- CloudWatch Logs ingestion and storage
- Reachability Analyzer analyses
- Cross-Availability-Zone or cross-VPC data transfer

Where practical, labs will use cost-conscious architectures and inspect configurations before creating chargeable resources.

**Safety principles:**

- Use a dedicated disposable VPC when modifying routing, NACLs, or shared network settings.
- Avoid intentionally disrupting production workloads.
- Never change a shared route table or DHCP option set without confirming ownership.
- Verify resource IDs and project tags before cleanup.
- Do not upload credentials, SSH private keys, or confidential logs.
- Prefer controlled and reversible failure scenarios.
- Delete unused resources after each exercise.

---

## Expected Skills After Completion

By completing these labs, the learner should gain practical experience in:

- VPC architecture and CIDR planning
- Public and private subnet connectivity
- IPv4 routing
- Internet gateway troubleshooting
- NAT gateway troubleshooting
- Stateful and stateless network security
- VPC DNS and private DNS
- Gateway and interface VPC endpoints
- VPC peering
- VPC Flow Logs interpretation
- Reachability Analyzer
- Network fault isolation
- AWS CLI investigation
- Root cause analysis
- Production-style remediation
- Secure AWS network design

---

## Intended Career Paths

This repository is designed to support practical preparation for:

- Cloud Engineer
- AWS Cloud Engineer
- Cloud Operations Engineer
- Cloud Security Engineer
- DevOps Engineer
- Platform Engineer
- Infrastructure Engineer

---

## Repository Structure

```text
aws-vpc-troubleshooting-labs/
│
├── README.md
│
├── 01-vpc-cidr-configuration-error/
├── 02-subnet-creation-failure/
├── 03-public-subnet-no-internet/
├── 04-private-subnet-no-internet/
├── 05-route-table-misconfiguration/
├── 06-security-group-blocks-traffic/
├── 07-network-acl-blocks-traffic/
├── 08-nat-gateway-connection-failure/
├── 09-vpc-dns-resolution-failure/
├── 10-vpc-endpoint-connection-failure/
├── 11-vpc-peering-connection-failure/
├── 12-vpc-flow-logs-investigation/
├── 13-reachability-analyzer-troubleshooting/
├── 14-interface-endpoint-private-dns-failure/
└── 15-multi-tier-vpc-connectivity-failure/
```

Lab directories will be added progressively as the hands-on exercises are developed.

---

## Learning Approach

This repository emphasizes practical troubleshooting rather than memorizing AWS service definitions.

Every exercise focuses on understanding the failure, collecting evidence, interpreting AWS behavior, applying a controlled fix, and verifying the result.

The repository is intended to demonstrate hands-on cloud networking and security troubleshooting skills.

---

## References

- [Amazon VPC Documentation](https://docs.aws.amazon.com/vpc/latest/userguide/)
- [Amazon VPC Route Tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [Amazon VPC Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html)
- [VPC Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html)
- [AWS CLI Documentation](https://docs.aws.amazon.com/cli/latest/reference/)

---

## Project Status

**Planned: 15 AWS VPC troubleshooting labs**

Labs will be implemented, tested, documented, and committed to GitHub individually.

**First lab:** `01-vpc-cidr-configuration-error`

**Goal:** Build a practical AWS networking troubleshooting portfolio using reproducible incidents, evidence-based root cause analysis, and secure remediation.
