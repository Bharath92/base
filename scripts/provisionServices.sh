#!/bin/bash -e

readonly release_file="$VERSIONS_DIR/$RELEASE_VERSION".json
local pulled_images="[]"
export SKIP_STEP=false

load_services() {
  local service_count=$(cat $STATE_FILE | jq '.services | length')
  if [[ $service_count -lt 3 ]]; then
    __process_msg "Shippable requires at least api, www and sync to boot"
    exit 1
  else
    __process_msg "Service count : $service_count"
  fi
}

__map_env_vars() {
  if [ "$1" == "DBNAME" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbname')
  elif [ "$1" == "DBUSERNAME" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbUsername')
  elif [ "$1" == "DBPASSWORD" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbPassword')
  elif [ "$1" == "DBHOST" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbHost')
  elif [ "$1" == "DBPORT" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbPort')
  elif [ "$1" == "DBDIALECT" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.dbDialect')
  elif [ "$1" == "SHIPPABLE_API_TOKEN" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.serviceUserToken')
  elif [ "$1" == "SHIPPABLE_VORTEX_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.apiUrl')/vortex
  elif [ "$1" == "SHIPPABLE_API_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.apiUrl')
  elif [ "$1" == "SHIPPABLE_WWW_PORT" ]; then
    env_value=50001
  elif [ "$1" == "SHIPPABLE_WWW_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.wwwUrl')
  elif [ "$1" == "SHIPPABLE_FE_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.wwwUrl')
  elif [ "$1" == "LOG_LEVEL" ]; then
    env_value=info
  elif [ "$1" == "SHIPPABLE_RDS_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.redisUrl')
  elif [ "$1" == "SHIPPABLE_ROOT_AMQP_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.amqpUrlRoot')
  elif [ "$1" == "SHIPPABLE_AMQP_DEFAULT_EXCHANGE" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.amqpDefaultExchange')
  elif [ "$1" == "RUN_MODE" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.runMode')
  # TODO: Populate this
  elif [ "$1" == "DOCKER_VERSION" ]; then
    env_value=1.9.1
  elif [ "$1" == "DEFAULT_CRON_LOOP_HOURS" ]; then
    env_value=2
  elif [ "$1" == "API_RETRY_INTERVAL" ]; then
    env_value=3
  elif [ "$1" == "PROVIDERS" ]; then
    env_value=ec2
  elif [ "$1" == "SHIPPABLE_EXEC_IMAGE" ]; then
    local step_exec_image=$(cat $STATE_FILE | jq -r '.systemSettings.stepExecImage')
    env_value=$step_exec_image
  elif [ "$1" == "EXEC_IMAGE" ]; then
    local step_exec_image=$(cat $STATE_FILE | jq -r '.systemSettings.stepExecImage')
    env_value=$step_exec_image
  elif [ "$1" == "SETUP_RUN_SH" ]; then
    env_value=true
  elif [ "$1" == "SHIPPABLE_AWS_ACCOUNT_ID" ]; then
    local shippable_aws_account_id=$(cat $STATE_FILE | jq -r '.systemSettings.shippableAwsAccountId')
    env_value=$shippable_aws_account_id
  elif [ "$1" == "GITHUB_LINK_SYSINT_ID" ]; then
    env_value=null
  # TODO: Populate this
  elif [ "$1" == "BITBUCKET_LINK_SYSINT_ID" ]; then
    env_value=null
  elif [ "$1" == "BITBUCKET_CLIENT_ID" ]; then
    env_value=null
  elif [ "$1" == "BITBUCKET_CLIENT_SECRET" ]; then
    env_value=null
  elif [ "$1" == "COMPONENT" ]; then
    env_value=$2
  elif [ "$1" == "JOB_TYPE" ]; then
    env_value=$3
  elif [ "$1" == "TRUCK" ]; then
    env_value=true
  elif [ "$1" == "IRC_BOT_NICK" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.ircBotNick')
  elif [ "$1" == "SHIP_TIME_LIMIT" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.hubspotShipTimeLimit')
  elif [ "$1" == "HUBSPOT_LIST_ID" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.hubspotListId')
  elif [ "$1" == "SHOULD_SIMULATE" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.hubspotShouldSimulate')
  else
    echo "No handler for env : $1, exiting"
    exit 1
  fi
}

_check_component_status() {
  local status=$(cat $STATE_FILE | jq '.installStatus.'"$1"'')
  if [ "$status" = true ]; then
    SKIP_STEP=true;
  fi
}

_update_install_status() {
  local update=$(cat $STATE_FILE | jq '.installStatus.'"$1"'='true'')
  _update_state "$update"
}

__save_service_config() {
  local service=$1
  local ports=$2
  local opts=$3
  local component=$4
  local job_type=$5

  __process_msg "Saving image for $service"
  local system_images_registry=$(cat $STATE_FILE | jq -r '.systemSettings.systemImagesRegistry')
  local service_repository=$(cat $release_file | jq -r --arg service "$service" '
    .serviceConfigs[] |
    select (.name==$service) | .repository')
  #local service_tag=$service"."$RELEASE_VERSION
  local service_tag=$(cat $STATE_FILE \
      | jq -r '.deployTag')
  local service_image="$system_images_registry/$service_repository:$service_tag"
  __process_msg "Image version generated for $service : $service_image"
  local image_update=$(cat $STATE_FILE | jq --arg service "$service" '
    .services  |=
    map(if .name == "'$service'" then
        .image = "'$service_image'"
      else
        .
      end
    )'
  )
  update=$(echo $image_update | jq '.' | tee $STATE_FILE)
  __process_msg "Successfully updated $service image"

  __process_msg "Saving config for $service"
  local env_vars=$(cat $release_file | jq --arg service "$service" '
    .serviceConfigs[] |
    select (.name==$service) | .envs')
  __process_msg "Found envs for $service: $env_vars"

  local env_vars_count=$(echo $env_vars | jq '. | length')
  __process_msg "Successfully read from version file: $service.envs ($env_vars_count)"

  env_values=""
  for i in $(seq 1 $env_vars_count); do
    local env_var=$(echo $env_vars | jq -r '.['"$i-1"']')

    # Never apply TRUCK env in production mode
    if [ "$env_var" == "TRUCK" ] && [ "$INSTALL_MODE" == "production" ]; then
      continue
    fi

    if [ "$env_var" == "JOB_TYPE" ] || \
      [ "$env_var" == "COMPONENT" ]; then

      if [ $service == "deploy" ] || [ $service == "manifest" ] \
        || [ $service == "provision" ] || [ $service == "release" ] \
        || [ $service == "rSync" ]; then
          __map_env_vars $env_var "stepExec" "$service"
        env_values="$env_values -e $env_var=$env_value"
      else
        __map_env_vars $env_var $component $job_type
        env_values="$env_values -e $env_var=$env_value"
      fi
    else
      __map_env_vars $env_var $component $job_type
      env_values="$env_values -e $env_var=$env_value"
    fi

  done

  # Proxy
  __process_msg "Adding $service proxy mapping"
  http_proxy=$(cat $STATE_FILE | jq -r '.systemSettings.httpProxy')
  https_proxy=$(cat $STATE_FILE | jq -r '.systemSettings.httpsProxy')
  no_proxy=$(cat $STATE_FILE | jq -r '.systemSettings.noProxy')

  if [ ! -z $http_proxy ]; then
    env_values="$env_values -e http_proxy=$http_proxy -e HTTP_PROXY=$http_proxy"
    __process_msg "Successfully updated $service http_proxy mapping"
  fi

  if [ ! -z $https_proxy ]; then
    env_values="$env_values -e https_proxy=$https_proxy -e HTTPS_PROXY=$https_proxy"
    __process_msg "Successfully updated $service https_proxy mapping"
  fi

  if [ ! -z $no_proxy ]; then
    env_values="$env_values -e no_proxy=$no_proxy -e NO_PROXY=$no_proxy"
    __process_msg "Successfully updated $service no_proxy mapping"
  fi

  local state_env=$(cat $STATE_FILE | jq --arg service "$service" '
    .services  |=
    map(if .name == $service then
        .env = "'$env_values'"
      else
        .
      end
    )'
  )
  update=$(echo $state_env | jq '.' | tee $STATE_FILE)

  local volumes=$(cat $release_file | jq --arg service "$service" '
    .serviceConfigs[] |
    select (.name==$service) | .volumes')
  if [ "$volumes" != "null" ]; then
    local volumes_update=""
    local volumes_count=$(echo $volumes | jq '. | length')
    for i in $(seq 1 $volumes_count); do
      local volume=$(echo $volumes | jq -r '.['"$i-1"']')
      volumes_update="$volumes_update -v $volume"
    done
    volumes_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .volumes = "'$volumes_update'"
        else
          .
        end
      )'
    )
    update=$(echo $volumes_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service volumes"
  fi

  # Ports
  # TODO: Fetch from systemConfig
  local port_mapping=$ports

  if [ ! -z $ports ]; then
    __process_msg "Generating $service port mapping"
    __process_msg "$service port mapping : $port_mapping"
    local port_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .port = "'$port_mapping'"
        else
          .
        end
      )'
    )
    update=$(echo $port_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service port mapping"
  fi

  # Opts
  # TODO: Fetch from systemConfig
  local opts=$3
  __process_msg "$service opts : $opts"

  if [ ! -z $opts ]; then
    __process_msg "Generating $service opts"
    local opt_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .opts = "'$opts'"
        else
          .
        end
      )'
    )
    update=$(echo $opt_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service opts"
  fi
}

__run_service() {
  service=$1
  delay=$2
  restart=$3

  __process_msg "Provisioning $service on swarm cluster"
  local swarm_manager_machine=$(cat $STATE_FILE | jq '.machines[] | select (.group=="core" and .name=="swarm")')
  local swarm_manager_host=$(echo $swarm_manager_machine | jq '.ip')

  local port_mapping=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .port')
  local env_variables=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .env')
  local name=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .name')
  local opts=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .opts')
  local image=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .image')
  local replicas=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .replicas')
  local volumes=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .volumes')

  if [ "$INSTALL_MODE" == "production" ]; then
    local boot_cmd="docker service create"

    if [ $port_mapping != "null" ]; then
      boot_cmd="$boot_cmd $port_mapping"
    fi

    if [ $env_variables != "null" ]; then
      boot_cmd="$boot_cmd $env_variables"
    fi

    if [ $replicas != "null" ]; then
      boot_cmd="$boot_cmd --replicas $replicas"
    else
      boot_cmd="$boot_cmd --mode global"
    fi

    if [ $opts != "null" ]; then
      boot_cmd="$boot_cmd $opts"
    fi

    boot_cmd="$boot_cmd $image"

    if ["$restart" == true]; then
      _exec_remote_cmd "$swarm_manager_host" "docker service rm $service || true"
    fi

    if [ ! -z "$delay" ]; then
      __process_msg "Waiting "$delay"s before "$1" restart..."
      sleep $delay
    fi

    _exec_remote_cmd "$swarm_manager_host" "$boot_cmd"
  else
    sudo docker rm -f $service || true

    # Pull image before attempting to run to ensure the image is always updated in
    # case it was overwritten. Like in case of :latest.
    # Don't try to pull an image if it was already pulled earlier during the install,
    # it will slow down provisioning.
    local is_image_pulled=$(echo $pulled_images | jq -r '.[] | select (.=="'$image'")')
    if [ -z "$is_image_pulled" ]; then
      pulled_images=$(echo $pulled_images | jq '. + ["'$image'"]')
      local pull_service_cmd="sudo docker pull $image"
      __process_msg "Pulling $image..."
      local pull_result=$(eval $pull_service_cmd)
    fi

    boot_cmd="sudo docker run -d "

    if [ $port_mapping != "null" ]; then
      boot_cmd="$boot_cmd $port_mapping"
    fi

    if [ $env_variables != "null" ]; then
      boot_cmd="$boot_cmd $env_variables"
    fi

    if [ $volumes != "null" ]; then
      boot_cmd="$boot_cmd $volumes"
    fi

    boot_cmd="$boot_cmd \
      --net host \
      --name $service \
      $image"

    eval $boot_cmd
  fi
  __process_msg "Successfully provisioned $service"
}

provision_www() {
  local sleep_time=30
  local restart=true
  __save_service_config www " --publish 50001:50001/tcp" "--mode global --name www --network ingress --with-registry-auth --endpoint-mode vip"
  __run_service "www" $sleep_time $restart
}

provision_state_less_services() {
  local services=$(cat $STATE_FILE | jq -c '[ .services[] ]')
  local services_count=$(echo $services | jq '. | length')
  local provisioned_services="[\"www\",\"api\"]"

  for i in $(seq 1 $services_count); do
    local service=$(echo $services | jq -r '.['"$i-1"'] | .name')
    local provisioned_service=$(echo $provisioned_services | jq -r '.[] | select (.=="'$service'")')
    if [ -z "$provisioned_service" ]; then
      __run_service "$service"
    fi
  done
}

remove_services_prod() {
  #TODO: Handle the scenario where the installer is not running on the swarm machine
  local running_services=$(docker service inspect --format='{{json .Spec.Name}},' $(sudo docker service ls -q))
  running_services="["${running_services::-1}"]"
  local required_services=$(cat $STATE_FILE | jq -c '[ .services[] ]')
  local ship_services=$(cat $release_file | jq -c '[ .serviceConfigs[] | .name]')
  local running_services_count=$(echo $running_services | jq '. | length')
  for i in $(seq 1 $running_services_count); do
    local service=$(echo $running_services | jq -r '.['"$i-1"']')
    if [[ ! $service =~ .*"local".* ]]; then
      local required_service=$(echo $ship_services | jq '.[] | select (.=="'$service'")')
      if [ ! -z "$required_service" ]; then
        required_service=$(echo $required_services | jq -r '.[] | select (.name=="'$service'") | .name')
        if [ -z "$required_service" ]; then
          local removed_service=$(docker service rm $service || true)
          __process_msg "$removed_service service removed"
        fi
      fi
    fi
  done
}

remove_services_local() {
  local running_services=$(echo "$(docker inspect --format='{{json .Name}}' $(docker ps -a -q))" | tr '\n' ',')
  local required_services=$(cat $STATE_FILE | jq -c '[ .services[] ]')
  local ship_services=$(cat $release_file | jq -c '[ .serviceConfigs[] | .name]')
  running_services="["${running_services::-1}"]"
  local running_services_count=$(echo $running_services | jq '. | length')
  for i in $(seq 1 $running_services_count); do
    local service=$(echo $running_services | jq -r '.['"$i-1"']')
    if [[ ! $service =~ .*"local".* ]]; then
      service=${service:1}
      local required_service=$(echo $ship_services | jq '.[] | select (.=="'$service'")')
      if [ ! -z "$required_service" ]; then
        required_service=$(echo $required_services | jq -r '.[] | select (.name=="'$service'") | .name')
        if [ -z "$required_service" ]; then
          local removed_service=$(sudo docker rm -f $service || true)
          __process_msg "$removed_service service removed"
        fi
      fi
    fi
  done
}

main() {
  __process_marker "Provisioning services"
  load_services
  provision_www
  provision_state_less_services
  if [ "$INSTALL_MODE" == "production" ]; then
    remove_services_prod
  else
    remove_services_local
  fi
}

main
