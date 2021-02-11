"""Automated install of NGINX Controller on Azure"""

import provisioners
import scripts

import pulumi
from pulumi import Output, ResourceOptions, ComponentResource
from pulumi_azure_nextgen.compute import latest as compute
from pulumi_azure_nextgen.resources import latest as resources
from pulumi_azure_nextgen.network import latest as network
from pulumi_azure_nextgen.dbforpostgresql import latest as postgresql
from pulumi_azure_nextgen.storage import latest as storage

azureConfig = pulumi.Config('azure')
location = azureConfig.get('location')

config = pulumi.Config()

# An id that uniquely identifies the Controller installation (defaults to the stack name)
installation_id = config.require('installation_id').lower() or pulumi.get_stack().lower()
if not installation_id.isalnum():
    raise ValueError('installation_id must only contain alphanumeric characters. '
                     'Invalid installation_id value: {0}'.format(installation_id))

# The user created on the Controller VM
controller_host_username = config.get('controller_host_username') or 'controller'
# The password for the user created on the Controller VM
controller_host_password = config.require_secret('controller_host_password')
# The email address used for Controller login and Let's Encrypt
admin_email = config.require('admin_email')
# The password used for logging into Controller
admin_password = config.require_secret('admin_password')
# The first name of the admin Controller user
admin_first_name = config.require('admin_first_name')
# The last name of the admin Controller user
admin_last_name = config.require('admin_last_name')
# Path to Controller install archive on local file system
controller_archive_path = config.require('controller_archive_path')
# Disk space in gigabytes for the data partition on the Controller VM
data_disk_size_gb = config.get_int('data_disk_size') or 130
# Email server settings
smtp_host = config.require('smtp_host')
smtp_port = config.require_int('smtp_port')
smtp_tls = config.require_bool('smtp_tls')
smtp_from = config.require('smtp_from')
smtp_auth = config.require_bool('smtp_auth')
if smtp_auth:
    smtp_user = config.require('smtp_user')
    smtp_pass = config.require_secret('smtp_pass')

# How to install PostgreSQL:
#  'local' installs it on the same VM as Controller
#  'sass' creates a new PostgreSQL instance using Azure's SasS offering
db_type = config.require("db_type")
if not db_type == 'sass' and not db_type == 'local':
    raise ValueError("db_type must be either 'sass' or 'local'. Invalid value: {0}".format(db_type))
if db_type == 'sass':
    # The admin user created on the new PostgreSQL instance
    db_admin_username = config.get('db_admin_username') or 'controller'
    # The password for the admin user on the new PostgreSQL instance
    db_admin_password = config.require_secret('db_admin_password')

pulumi.log.info("Azure Location: {0}".format(location))

resource_group = resources.ResourceGroup(
    resource_name='rg-nc',
    resource_group_name='rg-nc-{0}'.format(installation_id),
    location=location
)

storage_account = storage.StorageAccount(
    account_name='stnc{0}'.format(installation_id),
    resource_name='stnc',
    resource_group_name=resource_group.name,
    location=location,
    access_tier="Hot",
    enable_https_traffic_only=True,
    allow_blob_public_access=False,
    kind="StorageV2",
    sku=storage.SkuArgs(
        name="Standard_LRS",
    )
)

net = network.VirtualNetwork(
    resource_name='vnet-nc',
    resource_group_name=resource_group.name,
    virtual_network_name='vnet-nc-{0}'.format(installation_id),
    location=resource_group.location,
    enable_ddos_protection=False,
    enable_vm_protection=False,
    address_space=network.AddressSpaceArgs(
        address_prefixes=['10.0.0.0/16']
    )
)

subnet = network.Subnet(resource_name='snet-nc',
                        resource_group_name=resource_group.name,
                        virtual_network_name=net.name,
                        subnet_name='snet-nc-{0}'.format(installation_id),
                        service_endpoints=[
                            network.ServiceEndpointPropertiesFormatArgs(
                                locations=[location],
                                service='Microsoft.Sql',
                            )],
                        address_prefix="10.0.2.0/24",
                        private_endpoint_network_policies="Disabled",
                        private_link_service_network_policies="Enabled",
                        opts=ResourceOptions(depends_on=[net]))

# Default values are set to None because the user may have selected
# db_type == 'local' which allows for PostgreSQL to be installed on the
# VM instance instead of using Azure's PostgreSQL SasS offering.
db_server = None
db = None
if db_type == 'sass':
    # Build PostgreSQL NGINX Controller Config DB
    db_server = postgresql.Server(resource_name='psql-nc-db',
                                  resource_group_name=resource_group.name,
                                  location=location,
                                  server_name='config-db-{0}'.format(installation_id),
                                  sku=postgresql.SkuArgs(
                                      capacity=2,
                                      family="Gen5",
                                      name="GP_Gen5_2",
                                      tier="GeneralPurpose"),
                                  properties={
                                      "administratorLogin": db_admin_username,
                                      "administrator_login_password": db_admin_password,
                                      "infrastructure_encryption": "Disabled",
                                      "minimal_tls_version": "TLSEnforcementDisabled",
                                      "public_network_access": "Disabled",
                                      # Unfortunately, this setting isn't compatible with Controller yet
                                      "ssl_enforcement": "Disabled",
                                      "storage_profile": {
                                          "backup_retention_days": 7,
                                          "geo_redundant_backup": "Disabled",
                                          "storage_autogrow": "Enabled",
                                          "storage_mb": 40960,
                                      },
                                      "version": "9.5",
                                  })

    db = postgresql.Database(resource_name='psqldb-nc-db',
                             resource_group_name=resource_group.name,
                             database_name='controller-config',
                             charset='UTF8',
                             collation='en-US',
                             server_name=db_server.name)

public_ip = network.PublicIPAddress(resource_name='pip-nc',
                                    resource_group_name=resource_group.name,
                                    public_ip_address_name='pip-nc-{0}'.format(installation_id),
                                    location=location,
                                    dns_settings=network.PublicIPAddressDnsSettingsArgs(
                                        domain_name_label='controller-{0}'.format(installation_id.lower()),
                                    ),
                                    public_ip_address_version='IPv4',
                                    public_ip_allocation_method='Dynamic')

network_security_group = network.NetworkSecurityGroup(
    resource_name='nsg-nc',
    resource_group_name=resource_group.name,
    network_security_group_name='nsg-nc-{0}'.format(installation_id),
    location=location,
    security_rules=[
        network.SecurityRuleArgs(
            name='ssh',
            direction='Inbound',
            access='Allow',
            protocol='Tcp',
            source_port_range='*',
            destination_port_range='22',
            source_address_prefix='*',
            destination_address_prefix='*',
            priority=1000
        ),
        network.SecurityRuleArgs(
            name='http',
            direction='Inbound',
            access='Allow',
            protocol='Tcp',
            source_port_range='*',
            destination_port_range='80',
            source_address_prefix='*',
            destination_address_prefix='*',
            priority=1003
        ),
        network.SecurityRuleArgs(
            name='https',
            direction='Inbound',
            access='Allow',
            protocol='Tcp',
            source_port_range='*',
            destination_port_range='443',
            source_address_prefix='*',
            destination_address_prefix='*',
            priority=1001
        ),
        network.SecurityRuleArgs(
            name='agent-https',
            direction='Inbound',
            access='Allow',
            protocol='Tcp',
            source_port_range='*',
            destination_port_range='8443',
            source_address_prefix='*',
            destination_address_prefix='*',
            priority=1002
        ),
    ]
)

network_interface = network.NetworkInterface(resource_name='nic-nc',
                                             resource_group_name=resource_group.name,
                                             network_interface_name='nic-nc-{0}'.format(installation_id),
                                             location=location,
                                             ip_configurations=[network.NetworkInterfaceIPConfigurationArgs(
                                                 name='pipcfg-nc',
                                                 primary=True,
                                                 subnet=network.SubnetArgs(id=subnet.id),
                                                 private_ip_allocation_method='Dynamic',
                                                 public_ip_address=network.PublicIPAddressArgs(id=public_ip.id))],
                                             network_security_group=network.NetworkSecurityGroupArgs(
                                                 id=network_security_group.id))

# Build NGINX Controller VM

controller_fqdn = Output.all(public_ip.dns_settings).apply(lambda lst: lst[0])
custom_data = scripts.platform_setup_script({
    'TLS_HOSTNAME': scripts.build_vm_domain(config),
    'LETS_ENCRYPT_EMAIL': admin_email
})

controller_app_disk = compute.Disk(
    resource_name='disk-nc',
    resource_group_name=resource_group.name,
    disk_name='disk-nc-data',
    location=location,
    os_type=compute.OperatingSystemTypes.LINUX,
    disk_size_gb=data_disk_size_gb,
    creation_data=compute.CreationDataArgs(
        create_option=compute.DiskCreateOption.EMPTY))

vm = compute.VirtualMachine(
    resource_name='vm-nc',
    resource_group_name=resource_group.name,
    vm_name='vm-nc-{0}'.format(installation_id),
    location=location,
    hardware_profile=compute.HardwareProfileArgs(
        vm_size='Standard_B8ms'),
    os_profile=compute.OSProfileArgs(
        computer_name='nginx-controller',
        custom_data=custom_data,
        admin_username=controller_host_username,
        admin_password=controller_host_password
    ),
    identity=compute.VirtualMachineIdentityArgs(
        type='SystemAssigned'),
    network_profile=compute.NetworkProfileArgs(
        network_interfaces=[compute.NetworkInterfaceReferenceArgs(id=network_interface.id)]
    ),
    storage_profile=compute.StorageProfileArgs(
        data_disks=[{
            "caching": "ReadWrite",
            "create_option": "Attach",
            "disk_size_gb": data_disk_size_gb,
            # LUN 3 is referenced in the custom data partition install script, so it is
            # important that this value isn't changed without changing that script.
            "lun": 3,
            "managed_disk": {
                "id": controller_app_disk.id,
                "storage_account_type": "StandardSSD_LRS",
            },
            "to_be_detached": False,
        }],
        image_reference={
            "offer": "UbuntuServer",
            "publisher": "canonical",
            "sku": "18.04-LTS",
            "version": "latest",
        },
        os_disk={
            "caching": "ReadWrite",
            "create_option": "FromImage",
            "disk_size_gb": 30,
            "managed_disk": {
                "storage_account_type": "StandardSSD_LRS",
            },
            "os_type": "Linux",
        },
    ))

if db_server is not None:
    private_endpoint_resource = network.PrivateEndpoint(
        resource_name='ep-nctodb',
        resource_group_name=resource_group.name,
        private_endpoint_name='ep-nctodb-{0}'.format(installation_id),
        location=location,
        private_link_service_connections=[network.PrivateLinkServiceConnectionArgs(
            group_ids=['postgresqlServer'],
            private_link_service_id=db_server.id,
            name="psc-nctodb",
            private_link_service_connection_state={
                'actions_required': 'None',
                'description': 'Auto-approved',
                'status': 'Approved',
            },
        )],
        subnet=network.SubnetArgs(id=subnet.id)
    )

    private_dns_zone = network.PrivateZone(
        resource_name='z-ncdb',
        resource_group_name=resource_group.name,
        location='global',
        private_zone_name='privatelink.postgres.database.azure.com',
    )

    private_dns_zone_group = network.PrivateDnsZoneGroup(
        resource_name='pdnsg-ncdb',
        resource_group_name=resource_group.name,
        private_dns_zone_group_name='pdnsg-ncdb-{0}'.format(installation_id),
        private_dns_zone_configs=[network.PrivateDnsZoneConfigArgs(
            name='privatelink.postgres.database.azure.com',
            private_dns_zone_id=private_dns_zone.id
        )],
        private_endpoint_name=private_endpoint_resource.name
    )

    private_dns_vnet_link = network.VirtualNetworkLink(
        resource_name='zvnl-ncdb',
        resource_group_name=resource_group.name,
        location='global',
        virtual_network_link_name=net.name,
        virtual_network=network.SubResourceArgs(
            id=net.id),
        private_zone_name=private_dns_zone.name,
        registration_enabled=True,
        opts=ResourceOptions(depends_on=[private_dns_zone, private_dns_zone_group])
    )

conn = provisioners.ConnectionArgs(
    host="controller-{0}.{1}.cloudapp.azure.com".format(installation_id, location.lower()),
    username=controller_host_username,
    password=controller_host_password,
)

if db is None:
    resource_dependencies = [public_ip, vm]
else:
    resource_dependencies = [public_ip, db, vm]

copy_resources = ComponentResource(
    name='copy-controller-installer',
    t='remote:scp:CopyControllerInstallAssets',
    props={
        'cp_install_archive': provisioners.CopyFile(
            name='copy-controller-installer-archive'.format(installation_id),
            conn=conn,
            src=controller_archive_path,
            dest='/tmp/controller-installer.tar.gz',
            opts=pulumi.ResourceOptions(depends_on=resource_dependencies)
        ),
        'cp_secrets': provisioners.CopyString(
            name='copy-secrets_file',
            conn=conn,
            content=scripts.build_secrets(config),
            dest='/tmp/secrets.env',
            opts=pulumi.ResourceOptions(depends_on=resource_dependencies)
        ),
        'cp_controller_installer': provisioners.CopyFile(
            name='copy-controller-installer',
            conn=conn,
            src='install_controller.sh',
            dest='/tmp/install_controller.sh',
            opts=pulumi.ResourceOptions(depends_on=resource_dependencies)
        )
    },
    opts=pulumi.ResourceOptions(depends_on=resource_dependencies)
)

run_installer = provisioners.RemoteExec(
    name='run-controller-installer',
    conn=conn,
    commands=[
        'bash /tmp/install_controller.sh',
        'rm /tmp/secrets.env 2>1 /dev/null || true'
    ],
    opts=pulumi.ResourceOptions(depends_on=[copy_resources])
)

combined_output = Output.all(public_ip.name, public_ip.ip_address)

if db is not None:
    pulumi.export('config_db_name', db.name)
    pulumi.export('config_db_server_name', db.name)
    pulumi.export('config_db_username', db_admin_username)

pulumi.export('nginx_controller_host', controller_fqdn)
pulumi.export('nginx_controller_host_username', controller_host_username)
