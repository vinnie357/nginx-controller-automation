FROM pulumi/pulumi-python

COPY requirements.txt /pulumi/projects/nginx-controller-install/
COPY *.py /pulumi/projects/nginx-controller-install/
COPY *.sh /pulumi/projects/nginx-controller-install/
COPY Pulumi.yaml /pulumi/projects/nginx-controller-install/

WORKDIR /pulumi/projects/nginx-controller-install

RUN set -eux; \
    python3 -m pip install --prefix /usr/local wheel; \
    python3 -m pip install --prefix /usr/local -r requirements.txt; \
    sed --in-place '/virtualenv: venv$/d' Pulumi.yaml; \
    mkdir config installer-archives