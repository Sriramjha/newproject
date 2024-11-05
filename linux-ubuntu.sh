#!/bin/bash
# @licence     Apache-2.0
# @version     0.1.2
# @since       0.0.1

OPTIONS=$(getopt -o f:l: -l app-name:,sub-name:,cx-region:,api-key:,monitor-containers: -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    echo "Invalid option"
    exit 1
fi

cx_region_endpoint_resolver() {
    case "$1" in
        "EU1")
            echo "coralogix.com"
            ;;
        "EU2")
            echo "eu2.coralogix.com"
            ;;
        "AP1")
            echo "coralogix.in"
            ;;
        "US1")
            echo "coralogix.us"
            ;;
        "US2")
            echo "cx498.coralogix.com"
            ;;
        "AP2")
            echo "coralogixsg.com"
            ;;
        "AP3")
            echo "ap3.coralogix.com"
            ;;            
    esac
}

machine_architecture_resolver() {
  case "$1" in
      "x86_64")
          echo "amd64"
          ;;
      "armv7")
          echo "armv7"
          ;;
      "armv7l")
          echo "armv7"
          ;;
      "arm64")
          echo "arm64"
          ;;
      "ppc64le")
          echo "ppc64le"
          ;;
      "s390x")
          echo "s390x"
          ;;
  esac
}

validate_api_key() {
    key=$1
    if [[ $key =~ ^cxt[ph]_[A-Za-z0-9]{30}$|^[0-9A-f]{8}\-[0-9A-f]{4}\-[0-9A-f]{4}\-[0-9A-f]{4}\-[0-9A-f]{12}$ ]]; then
        return 0
    else
        return 1
    fi
}

eval set -- "$OPTIONS"

app_name=""
sub_name=""
cx_region=""
api_key=""
monitor_containers="false"

while true; do
    case "$1" in
        --app-name)
            app_name="$2"
            if ! [[ "$app_name" =~ ^[A-Za-z0-9\_\@\.\-]{3,50}$ ]]; then
                echo "Error: Invalid application name format. should be a string with 3 to 50 characters."
                exit 1
            fi
            shift 2;;
        --sub-name)
            sub_name="$2"
            if ! [[ "$sub_name" =~ ^[A-Za-z0-9\_\@\.\-]{3,50}$ ]]; then
                echo "Error: Invalid subsystem name format. should be a string with 3 to 50 characters."
                exit 1
            fi
            shift 2;;
        --cx-region)
            cx_region=$(cx_region_endpoint_resolver "$2")
            if ! [[ "$2" =~ ^(EU|AP|US)[123]$ ]]; then
                echo "Error: Invalid cx-region format. should follow the regex ^(EU|AP|US)[123]$"
                exit 1
            fi
            shift 2;;
        --api-key)
            api_key="$2"
            if ! validate_api_key "$api_key"; then
                echo "Error: Invalid API key format"
                exit 1
            fi
            shift 2;;
        --monitor-containers)
            monitor_containers="$2"
            shift 2;;
        *)
            break;;
    esac
done

if [ -z "$app_name" ] || [ -z "$sub_name" ] || [ -z "$cx_region" ] || [ -z "$api_key" ]; then
    echo "Usage: $0 --app-name <App_Name> --sub-name <Sub_Name> --cx-region <CX_Region> --api-key <API_Key> [--monitor-containers <true/false>]"
    exit 1
fi

if [[ "$monitor_containers" == "true" ]]; then
    read -p "DISCLAIMER: To collect container logs, OpeTelemetry needs to run as Root. Continue? (yes/no): " response
    if [ "$response" = "yes" ]; then
        docker_input="- /var/lib/docker/containers/*/*.log"

        # Making Otel run as root
        sed -i "s@User=@#User=@" /usr/lib/systemd/system/otelcol-contrib.service
        sed -i "s@Group=@#Group=@" /usr/lib/systemd/system/otelcol-contrib.service
        systemctl daemon-reload
    fi

elif [[ "$monitor_containers" == "false" ]]; then
    docker_input=""
else
    echo "Error: Invalid value for monitor-containers. It should be 'true' or 'false'"
    exit 1
fi

otel_conf="receivers:
  filelog:
    include:
      - /var/log/auth.log
      - /var/log/syslog
processors:
  batch: {}
  resourcedetection/env:
    detectors: [env, system]
    system:
      hostname_sources: ['os']
      resource_attributes:
        host.id:
          enabled: true
  resourcedetection/cloud:
    detectors: ['gcp', 'ec2', 'azure']
    timeout: 2s
    override: false
    ec2:
      resource_attributes:
        cloud.availability_zone:
          enabled: true
        cloud.region:
          enabled: true
exporters:
  coralogix:
    domain: '$cx_region'
    private_key: '$api_key'
    subsystem_name_attributes:
      - 'host.name'
    application_name: '$app_name'
    subsystem_name: '$sub_name'
    timeout: 30s
service:
  pipelines:
    logs:
      receivers:
        - filelog
      processors:
        - resourcedetection/env
        - resourcedetection/cloud
        - batch
      exporters:
        - coralogix"

os_release_file="/etc/os-release"
os_id=$(cat "$os_release_file" | grep -E "^ID=" | awk -F'=' '{print $2}' | tr -d '"')

machine_architecture=$(machine_architecture_resolver "$(uname -m)")

if [ "$os_id" = "ubuntu" ]; then
  wget -O otelcol.deb https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.94.0/otelcol-contrib_0.94.0_linux_"$machine_architecture".deb
  dpkg -i otelcol.deb
  rm otelcol.deb
elif [ "$os_id" = "amzn" ] || [ "$os_id" = "rhel" ] || [ "$os_id" = "centos" ]; then
  wget -O otelcol.rpm https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.94.0/otelcol-contrib_0.94.0_linux_"$machine_architecture".rpm
  rpm -i otelcol.rpm
  rm otelcol.rpm
fi

if [ "$monitor_containers" = "false" ]; then
  chmod 644 /var/log/*.log
fi
echo "$otel_conf" > /etc/otelcol-contrib/config.yaml
systemctl enable otelcol-contrib.service
systemctl restart otelcol-contrib.service
