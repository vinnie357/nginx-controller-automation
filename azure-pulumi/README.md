# Installing NGINX Controller on Azure with Pulumi

This project provides an example of using [Pulumi](https://www.pulumi.com/) (an
infrastructure provisioning utility) to install and configure 
[NGINX Controller](https://www.nginx.com/products/nginx-controller/) on Azure.

Controller installation can be done directly using Pulumi's Python support or
alternatively by using Docker.

[![Screen capture of NGINX Controller install](https://asciinema.org/a/390888.svg)](https://asciinema.org/a/390888?autoplay=1)

## Getting Started (Quick Start Scripts)

This project provides [a script](setup/base_setup.sh) that will set up Python 3, 
Pulumi and the Azure CLI for this project. Additionally, it will install the 
Python modules needed for the project. The script supports MacOS, Ubuntu, 
Debian, CentOS, and Fedora. It should work with any Debian or RHEL compatible 
Linux distribution.

Run the script by:
```
bash setup/base_setup.sh
```

Once your environment is set up, then proceed to logging into Pulumi / Azure,
and configuring Pulumi's runtime settings by running the following command. If
Pulumi prompts you for a stack name, you can use the value `demo` as we are
using here.
```
bash setup/project_setup.sh
```

Now, we can stand up Controller with one command!
```
pulumi up
```

## Getting Started (Manual Steps)

In order to run this project, Python 3.6+ with the 
[Venv](https://docs.python.org/3/library/venv.html) module installed is required. 
Additionally, you will need to install [Pulumi](https://www.pulumi.com/docs/get-started/install/)
and [configure it to for Azure](https://www.pulumi.com/docs/intro/cloud-providers/azure/setup/).

Next, login to Pulumi.
```
pulumi login
```

Once Pulumi is set up, download a Controller installer archive from 
[My F5](https://my.f5.com/manage/s/) and copy it into the local subdirectory 
`installer-archives`.

Now, if you haven't already create a [stack](https://www.pulumi.com/docs/intro/concepts/stack/) 
and select it for this project:
```
pulumi stack init demo
pulumi stack select demo
```

Next, define the configuration that Pulumi will use to install Controller by creating a file
within the `config` subdirectory named `Pulumi.demo.yaml`. Replace the string 'demo' with
the name of your stack as appropriate. Using the template below we can add the configuration
values need for our installation.

```yaml
config:
  # Azure region to deploy to
  azure:location: WestUS
  # An id that uniquely identifies the Controller installation (defaults to the lowercase stack name).
  # You probably want to set this because there can be resource name conflicts on Azure with
  # the domain name assigned to the VM. This id must be lowercase using only letters or numbers
  # with no additional punctuation.
  nginx-controller:installation_id: uniquestring1122
  # Email address to associate with the administrator of Controller. This value is used by
  # Controller to send password resets as well as by Let's Encrypt as the administrative
  # contact address.
  nginx-controller:admin_email: myname@mydomain.tld
  # The first name of the administrator of Controller
  nginx-controller:admin_first_name: First
  # The last name of the administrator of Controller
  nginx-controller:admin_last_name: Last
  # The password for the Controller UI
  nginx-controller:admin_password:
    secure:
  # Path to Controller install archive on local file system
  nginx-controller:controller_archive_path: installer-archives/controller-installer-3.13.0.tar.gz
  # The password for the user created on the Controller VM
  nginx-controller:controller_host_password:
    # Be sure to leave this as is and not set it
    secure: 
  # The user created on the Controller VM (defaults to 'controller' if unset)
  nginx-controller:controller_host_username: controller
  # Value determines how PostgreSQL is installed:
  #  'local' installs it on the same VM as Controller
  #  'sass' creates a new PostgreSQL instance using Azure's SasS offering
  nginx-controller:db_type: local
  # The admin user created on the new PostgreSQL instance (defaults to 'controller' if unset).
  # This value only needs to be set if you are installing with db_type == 'sass'
  nginx-controller:db_admin_password:
    # Be sure to leave this as is and not set it
    secure: 
  
  # SMTP Settings
  # The Controller installer requires SMTP settings to be set in order to execute. However,
  # it does not require that the settings are valid. If the settings are invalid, then emails
  # from Controller will not work but it will otherwise function normally.
  # If you want an SMTP server on Azure, explore the SendGrid SasS offering.
  
  # Boolean flag indicating if the SMTP server requires authentication
  nginx-controller:smtp_auth: "true"
  # From address for Controller to send emails from
  nginx-controller:smtp_from: controller@mydomain.tld
  # SMTP hostname
  nginx-controller:smtp_host: smtp.sendgrid.net
  # SMTP username (needed if SMTP authentication is enabled)
  nginx-controller:smtp_user: apikey
  # SMTP password (needed if SMTP authentication is enabled)
  nginx-controller:smtp_pass:
    # Be sure to leave this as is and not set it
    secure: 
  # SMTP port number
  nginx-controller:smtp_port: "465"
  # Boolean flag indicating if TLS is required with SMTP
  nginx-controller:smtp_tls: "true"
```

After creating the configuration file and populating the settings above, use the
Pulumi CLI to set the secrets for the environment. This will add encrypted values for
the portion of the configuration that is has a "secure" sub-key.
```
pulumi config set --secret nginx-controller:admin_password
pulumi config set --secret nginx-controller:controller_host_password
# Only needed if using SasS for the database
pulumi config set --secret nginx-controller:db_admin_password
# Only needed if using SMTP authentication
pulumi config set --secret nginx-controller:smtp_pass
```

Next, set up python venv. Typically, you can do this by executing the following
in your working directory:
```
python3 -m venv venv
```

If you get a message about venv not being found, you will need to install it. 
On Ubuntu, this can be done by `sudo apt-get install python3-venv`.

From here, we activate the venv environment by:
```
source venv/bin/activate
```

The next step is to install the python dependencies using pip:
```
# Wheel will allow us to quickly install prebuilt python packages
pip3 install wheel
# Install project dependencies
pip3 install -r requirements.txt
```

Now, we can stand up Controller with one command!
```
pulumi up
```

## Getting Started with Docker

Running this project with Docker is similar to running it standalone, but when using
Docker you do not need to install Python nor Pulumi because that is done for you in
the Docker container.

To get started, first build the Docker image.
```
docker build -t controller-install .
```

Once the container is built, you will need to set up a service principle on Azure.
The Pulumi documentation will guide you on how to set up
[Service Principle Authentication](https://www.pulumi.com/docs/intro/cloud-providers/azure/setup/#service-principal-authentication).
Note the Azure `client id`, `client secret`, `tenant id` and `subscription id` because
you will need those settings when running the Docker container.

Next, [create a Pulumi access token](https://app.pulumi.com/elijah/settings/tokens) for 
your account and note the value.

To simplify usage, let's create an alias of the Docker run command so that we can
easily invoke Pulumi using Docker. Here you will need to insert the service principle
parameters and Pulumi access token that you noted from the above step.
```
alias nc_pulumi='docker run --interactive --tty --rm \
    --env 'ARM_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' \
    --env 'ARM_CLIENT_SECRET=V_xxxx_xxxxxxxxxxxx-xxxxxxxxxxxxxx' \
    --env 'ARM_TENANT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' \
    --env 'ARM_SUBSCRIPTION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' \
    --env 'PULUMI_ACCESS_TOKEN=pul-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
    --volume "$(pwd)/config:/pulumi/projects/nginx-controller-install/config" \
    --volume "$(pwd)/installer-archives:/pulumi/projects/nginx-controller-install/installer-archives" \
    controller-install:latest pulumi'
```

Create a new stack and select by:
```    
nc_pulumi stack init demo
nc_pulumi stack select demo
```

Follow the directions in the previous getting started section to create a new configuration file
at the path `config/Pulumi.demo.yaml` and populated with the appropriate values.

Next, set the secrets:
```
nc_pulumi config set --secret nginx-controller:admin_password
nc_pulumi config set --secret nginx-controller:controller_host_password
# Only needed if using SasS for the database
nc_pulumi config set --secret nginx-controller:db_admin_password
# Only needed if using SMTP authentication
nc_pulumi config set --secret nginx-controller:smtp_pass
```

Now, we can stand up Controller with one command!
```
nc_pulumi up
```