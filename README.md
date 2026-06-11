# NVIDIA GPU Accelerated Application Samples on Amazon Web Services (AWS)

**Table Of Contents**
- [Description](#description)
- [Support Level](#support-level)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Samples](#samples)
- [Usage](#usage)
- [Known Issues](#known-issues)
- [Contributions](#contributions)
- [Support](#support)
- [License](#license)

## Description

This repository maintains sample applications designed for NVIDIA software tools integrated with Amazon Web Services (AWS).

For select demonstrations, the sample code is contained within this repository. For others, we reference and link to exceptional demonstrations available outside of this repository.

## Support Level

These samples are provided as community examples and are not covered by NVIDIA Enterprise Support. They are intended as reference implementations to help users get started with NVIDIA software on AWS. See [Support](#support) below for how to get help.

## Requirements

- An active [Amazon Web Services (AWS)](https://aws.amazon.com/) account with permissions to create the resources used by a given sample
- Access to NVIDIA GPU instances in your target AWS region (e.g., A10G, A100, H100, H200)
- The AWS CLI installed and configured, or access to the AWS Management Console
- Additional, sample-specific prerequisites are documented in each sample's own README

## Quickstart

1. Clone this repository:
   ```bash
   git clone https://github.com/NVIDIA/nvidia-aws-samples.git
   cd nvidia-aws-samples
   ```
2. Browse the [Samples](#samples) section below and pick the one that matches your use case.
3. Follow the README inside that sample's directory for setup and run instructions.

## Samples

Samples are organized by AWS service:

- [`bedrock-samples/`](./bedrock-samples) — Samples that run on [Amazon Bedrock](https://aws.amazon.com/bedrock/), fully managed serverless inference.
- [`eks-samples/`](./eks-samples) — Samples that run on [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), self-managed deployment on Kubernetes.

## Usage

Each sample directory contains its own README with detailed deployment and usage instructions. In general:

1. Provision the required AWS infrastructure (cluster, compute, networking, storage) as described in the sample.
2. Deploy the NVIDIA software components.
3. Run the included workloads or applications.
4. Clean up the resources when you are done to avoid unnecessary charges.

## Known Issues

None at this time.

## Contributions

Contributions are welcome. Developers can contribute by opening a [pull request](https://help.github.com/en/articles/about-pull-requests) and agreeing to the terms in [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

For questions or issues:
- Open a [GitHub issue](https://github.com/NVIDIA/nvidia-aws-samples/issues) for bug reports or feature requests
- Refer to each sample's README for sample-specific guidance

To report a security vulnerability, follow the process in [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE). This project is licensed under the Apache License 2.0.
