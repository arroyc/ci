#!/bin/bash

# TODO Rename script

function print_usage() {
  cat <<EOF
Command
  $0
Arguments
  --scenario_name|-sn     [Required]: Scenario name
  --template_name|-tn     [Required]: Quickstart template name
  --app_id|-ai            [Required]: Service principal app id
  --app_key|-ak           [Required]: Service principal app key
  --tenant_id|-ti                   : Tenant id, defaulted to the Microsoft tenant id
  --user_name|-un                   : User name
  --region|-r                       : Region
  --keep_alive_hours|-kah           : The max number of hours to keep this deployment, defaulted to 48
  --kubernetes|-k                   : If the kube config file should be copied over
EOF
}

function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "Parameter '$name' cannot be empty." 1>&2
    print_usage
    exit -1
  fi
}

function try_replace_parameter() {
  local data="$1"
  local name="$2"
  local value="$3"
  echo "$data" | python -c "
import json, sys;
data=json.load(sys.stdin);
try:
  data['parameters']['$name']['value'] = '$value'
except:
  pass
print json.dumps(data)"
}

tenant_id="72f988bf-86f1-41af-91ab-2d7cd011db47"
user_name="testuser"
region="eastus"
keep_alive_hours="48"

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --scenario_name|-sn)
      scenario_name="$1"
      shift
      ;;
    --template_name|-tn)
      template_name="$1"
      shift
      ;;
    --app_id|-ai)
      app_id="$1"
      shift
      ;;
    --app_key|-ak)
      app_key="$1"
      shift
      ;;
    --tenant_id|-ti)
      tenant_id="$1"
      shift
      ;;
    --user_name|-un)
      user_name="$1"
      shift
      ;;
    --region|-r)
      region="$1"
      shift
      ;;
    --kubernetes|-k)
      kubernetes="$1"
      shift
      ;;
    --keep_alive_hours|-kah)
      keep_alive_hours="$1"
      shift
      ;;
    --help|-help|-h)
      print_usage
      exit 13
      ;;
    *)
      echo "ERROR: Unknown argument '$key' to script '$0'" 1>&2
      exit -1
  esac
done

throw_if_empty --scenario_name $scenario_name
throw_if_empty --template_name $template_name
throw_if_empty --app_id $app_id
throw_if_empty --app_key $app_key
throw_if_empty --tenant_id $tenant_id
throw_if_empty --user_name $user_name
throw_if_empty --region $region
throw_if_empty --keep_alive_hours $keep_alive_hours

# Create ssh key
mkdir $scenario_name
temp_key_path=$scenario_name/temp_key
ssh-keygen -t rsa -N "" -f $temp_key_path -V "+1d"
temp_pub_key=$(cat ${temp_key_path}.pub)

parameters=$(curl -s https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/$template_name/azuredeploy.parameters.json)
parameters=$(try_replace_parameter "$parameters" "servicePrincipalAppId" "$app_id")
parameters=$(try_replace_parameter "$parameters" "servicePrincipalAppKey" "$app_key")
parameters=$(try_replace_parameter "$parameters" "adminUsername" "$user_name")
parameters=$(try_replace_parameter "$parameters" "sshPublicKey" "$temp_pub_key")
parameters=$(try_replace_parameter "$parameters" "adminPassword" "$(uuidgen -r)")
parameters=$(try_replace_parameter "$parameters" "spinnakerDnsLabelPrefix" "$scenario_name")
parameters=$(try_replace_parameter "$parameters" "jenkinsDnsLabelPrefix" "$scenario_name")
parameters=$(try_replace_parameter "$parameters" "dnsLabelPrefix" "$scenario_name")
# parameters=$(try_replace_parameter "$parameters" "gitRepository" "https://github.com/lwander/spin-kub-demo.git")

az login --service-principal -u $app_id -p $app_key --tenant $tenant_id
az group create -n $scenario_name -l $region --tags "CleanTime=$(date -d "+${keep_alive_hours} hours" +%s)"
deployment_data=$(az group deployment create -g $scenario_name --template-uri https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/$template_name/azuredeploy.json --parameters "$parameters")

provisioningState=$(echo "$deployment_data" | python -c "import json, sys; data=json.load(sys.stdin);print data['properties']['provisioningState']")
if [ "$provisioningState" != "Succeeded" ]; then
    echo "Deployment failed." 1>&2
    exit -1
fi

if [ "$kubernetes" == "true" ]; then
  az acs kubernetes get-credentials --resource-group=$scenario_name --name=containerservice-$scenario_name --ssh-key-file=$temp_key_path
fi

fqdn=$(echo "$deployment_data" | python -c "
import json, sys;
data=json.load(sys.stdin)
if 'spinnakerFQDN' in data['properties']['outputs']:
  print data['properties']['outputs']['spinnakerFQDN']['value']
if 'jenkinsVmDns' in data['properties']['outputs']:
  print data['properties']['outputs']['jenkinsVmDns']['value']
if 'devOpsVmFQDN' in data['properties']['outputs']:
  print data['properties']['outputs']['devOpsVmFQDN']['value']"
)

# If the template didn't setup an ssh key, set one up for a few reasons:
# 1. There's not a great way to programatically ssh with a password (you have to use 'expect')
# 2. To be consistent across all tests
# 3. To be more secure
if [[ "$parameters" != *"sshPublicKey"* ]]; then
  # TODO: Implement after this bug in the az cli is fixed https://github.com/Azure/azure-cli/issues/2616
fi

# Setup ssh port forwarding
temp_ctl=$scenario_name/tunnel.ctl
cat <<EOF >"$scenario_name/ssh_config"
Host tunnel-start
  HostName $fqdn
  IdentityFile $temp_key_path
  ControlMaster yes
  ControlPath $temp_ctl
  RequestTTY no
  # Spinnaker/gate
  LocalForward 8084 127.0.0.1:8084
  User $user_name
  StrictHostKeyChecking no

Host tunnel-stop
  HostName $fqdn
  IdentityFile $temp_key_path
  ControlPath $temp_ctl
  RequestTTY no
EOF