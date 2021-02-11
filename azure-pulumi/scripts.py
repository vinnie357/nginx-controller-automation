import re
from typing import Dict

import pulumi
from pulumi_azure import config as az_config

import base64


def build_vm_domain(config: pulumi.Config) -> str:
    return 'controller-{0}.{1}.cloudapp.azure.com'.format(
        config.require('installation_id'),
        az_config.location.lower())


def platform_setup_script(substitutions: Dict[str, str]) -> str:
    matcher = re.compile(r"""^\s*(export\s+)*(\S+?)\s*=\s*[\"|'](.*?)[\"|'].*$""")
    pulumi.log.debug('Substituting: {0}'.format(substitutions))

    def substitute_params(line: str) -> str:
        match = matcher.match(line)
        if match:
            substitution = substitutions.get(match.group(2))
            if substitution:
                if match.group(1):
                    # write 'export ' if it is present on the original line
                    return match.group(1)

                return '{0}="{1}"\n'.format(match.group(2), substitution)
            else:
                return line
        else:
            return line

    with open('ubuntu_platform_setup.sh', 'r') as file:
        with_substitutions = map(substitute_params, file.readlines())

    setup_script = bytes(''.join(with_substitutions), 'utf-8')
    encoded = base64.b64encode(setup_script)
    return encoded.decode('ascii')


def build_secrets(config: pulumi.Config):
    secrets_template = """export CTR_FQDN="{fqdn}"
export CTR_EMAIL="{email}"
export CTR_PASSWORD="{admin_pass}"
export CTR_FIRSTNAME="{admin_first_name}"
export CTR_LASTNAME="{admin_last_name}"
export CTR_SMTP_HOST={smtp_host}
export CTR_SMTP_PORT={smtp_port}
export CTR_SMTP_TLS={smtp_tls}
export CTR_SMTP_AUTH={smtp_auth}
export CTR_SMTP_FROM={smtp_from}
"""

    if config.get('db_type') == 'sass':
        secrets_template += """export PG_INSTALL_TYPE=sass
export CTR_DB_HOST="{db_hostname}"
export CTR_DB_USER="{db_user}"
export CTR_DB_PASS="{db_pass}"
"""
    elif config.get('db_type') == 'local':
        secrets_template += 'export PG_INSTALL_TYPE=local\n'

    if config.get_bool('smtp_auth'):
        if config.get('smtp_user'):
            secrets_template += 'export CTR_SMTP_USER={0}\n'.format(config.get('smtp_user'))
        if config.get('smtp_pass'):
            secrets_template += 'export CTR_SMTP_PASS={0}\n'.format(config.get('smtp_pass'))

    hostname = build_vm_domain(config)
    db_admin_username = config.get('db_admin_username') or 'controller'
    installation_id = config.get('installation_id')

    values = {
        'fqdn': hostname,
        'email': config.get('admin_email'),
        'admin_pass': config.get('admin_password'),
        'admin_first_name': config.get('admin_first_name'),
        'admin_last_name': config.get('admin_last_name'),
        'db_hostname': 'config-db-{0}.postgres.database.azure.com'.format(installation_id),
        'db_user': '{0}@config-db-{1}'.format(db_admin_username, installation_id),
        'db_pass': config.get('db_admin_password'),
        'smtp_host': config.get('smtp_host'),
        'smtp_port': config.get('smtp_port'),
        'smtp_tls': 'true' if config.get_bool('smtp_tls') else 'false',
        'smtp_from': config.get('smtp_from'),
        'smtp_auth': 'true' if config.get_bool('smtp_auth') else 'false'
    }

    return secrets_template.format_map(values)
