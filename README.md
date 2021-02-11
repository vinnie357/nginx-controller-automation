# NGINX Controller Automation Examples

This repository contains projects that serve as examples for automating the
installation or administration of [NGINX Controller](https://www.nginx.com/products/nginx-controller/).

## Projects

### [Controller Installation on Azure with Pulumi and Python](azure-pulumi)

This project provides an example of installing Controller on Azure using
[Pulumi](https://www.pulumi.com/) for infrastructure deployment and bash
scripts for instance setup and installation automation. Infrastructure 
configuration is defined in a Python script that Pulumi executes to
stand up Azure instances and services. Key features of this project are:

 * Suitable for production or trial product usage
 * Pulumi with the Azure nextgen provider
 * Python based infrastructure definition
 * Optional support for [Azure's SasS offering for PostgreSQL](https://azure.microsoft.com/en-us/services/postgresql/)
 * Bash based instance configuration
 * Dedicated expandable (using XFS) data partitions
 * Ephemeral storage configuration for local cache 

### [Controller Installation on AWS with Terraform and Ansible](aws-terraform-ansible)

This project provides a demo of using [Packer](https://www.packer.io/), 
[Terraform](https://www.terraform.io/), and [Ansible](https://www.ansible.com/)
to install NGINX Controller on AWS. Infrastructure is defined by Terraform
configuration files. Ansible is set up on instances using Packer. Controller
install is performed by Ansible. Key features of this project are:

 * Demo project
 * Terraform and Packer with AWS provider
 * PostgreSQL installed as a separate instance from Controller
 * Mock SMTP server
 * NGINX Plus instance install
 * Ansible Playbook orchestrated installation

## License

[Apache 2.0](./LICENSE)