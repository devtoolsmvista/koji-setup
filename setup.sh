#!/bin/bash

set -xe
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOPDIR=/tmp/koji-setup
KOJI_JENKINS_SETUP_REPO=git://gitcentos.mvista.com/centos/upstream/docker/koji-jenkins-setup.git

# Docker Stack names 
STACK_KOJI=koji

#Docker images
IMAGE_KOJI_DB="postgres:9.4"
IMAGE_KOJI_HUB="yufenkuo/koji-hub:latest"
IMAGE_KOJI_BUILDER="yufenkuo/builder-launcher:latest"
IMAGE_KOJI_JENKINS="yufenkuo/koji-jenkins:latest"
IMAGE_KOJI_CLIENT="yufenkuo/koji-client:latest"

if [ -z "$HOST" ] ; then
    echo Please export HOST as the fully qualified domain name
    echo export HOST=foo.mvista.com
    exit 1
fi
if [ -z "$HOST_IP" ] ; then
    HOST_IP="$(hostname -i)"
    export HOST_IP="$(hostname -i)"
fi

if ! ping $HOST -c 1 >/dev/null 2>/dev/null; then
    echo "$HOST does not appear to be reachable from this machine."
    echo "if ping does not work, it won't work in the container and will fail to start"
    exit 1
fi
if ! ping $HOST_IP -c 1 >/dev/null 2>/dev/null; then
    echo "$HOST_IP does not appear to be reachable from this machine."
    echo "if ping does not work, it won't work in the container and will fail to start"
    exit 1
fi


#HOST=ec2-3-91-32-67.compute-1.amazonaws.com
#export HOST=ec2-3-91-32-67.compute-1.amazonaws.com

create_nginx_default_conf(){

    if [ ! -f /tmp/koji-setup/default.conf ]; then
      cat <<EOF >> /tmp/koji-setup/default.conf 
server {
    listen       80 default_server;
    server_name  localhost;
    root /usr/share/nginx/html;
    access_log  /var/log/nginx/host.access.log  main;
    error_log  /var/log/nginx/host.error.log  warn;

    location / {
        index index.html;
        proxy_pass http://${HOST_IP}:9080;
    }
    location /centos {
        root /mirrors/centos7;
        autoindex on;
        autoindex_exact_size off;
    }
    location /source-archive {
        root /mirrors/centos7;
        autoindex on;
        autoindex_exact_size off;
    }

    #error_page  404              /404.html;

    # redirect server error pages to the static page /50x.html
    #
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
EOF

    fi
}

prepare_working_directory () {
    if [ -d "$TOPDIR" ]; then
      sudo rm -rf "$TOPDIR"/*
    else
      mkdir -p $TOPDIR
    fi
    cd $TOPDIR
    git clone $KOJI_JENKINS_SETUP_REPO
    cd koji-jenkins-setup
    source run-scripts/parameters.sh
    sudo rm -rf $KOJI_CONFIG/*
    sudo rm -rf $KOJI_OUTPUT/*
}

prepare_koji_hub_container_setup () {
    mkdir -p $KOJI_OUTPUT $KOJI_CONFIG
    # Provide inital apps.list
    if [ -d "$KOJI_CONFIG"/koji ]; then
      sudo rm -rf "$KOJI_CONFIG"/koji/*
    else
      mkdir -p $KOJI_CONFIG/koji/
    fi
    cp $TOPDIR/koji-jenkins-setup/configs/app.list $KOJI_CONFIG/koji/
}

prepare_jenkins_container_setup () {
    if [ -d "$JENKINS_HOME" ]; then
      sudo rm -rf "$JENKINS_HOME"/*
    else
      mkdir -p $JENKINS_HOME
    fi
}

rm_existing_docker_stack () {
  result="$(docker stack ls | grep $STACK_KOJI | awk '{print $1}' )"
  if [ -n "$result" ] &&  [ $stackname = $result ]; then
      echo "Removing Docker Stack $stackname"
      docker stack rm $stackname
      sleep 5
  fi
}
pull_docker_images () {
  #Pull latest images
  images="$IMAGE_KOJI_DB $IMAGE_KOJI_BUILDER $IMAGE_KOJI_JENKINS"
  for image in $images
  do
    docker pull $image
  done

}
startup_koji_hub () {
  sudo rm -rf $KOJI_CONFIG/.done
  docker stack deploy --compose-file $SCRIPT_DIR/docker-compose.yml  $STACK_KOJI
  while [ ! -e $KOJI_CONFIG/.done -a ! -e $KOJI_CONFIG/.failed ] ; do
	echo -n "."
	sleep 10 
  done
  if [ -e $KOJI_CONFIG/.failed -a ! $KOJI_CONFIG/.done ] ; then
   echo "ERROR: Koji Hub start failed."
   docker service logs koji_koji-hub
   exit 1
  fi
}
bootstrap_build_in_koji_client_container() {
  mkdir -p $TOPDIR/koji-jenkins-setup/run-scripts2
  cp $TOPDIR/koji-jenkins-setup/run-scripts/* $TOPDIR/koji-jenkins-setup/run-scripts2
  yes | cp -rf /home/ec2-user/koji-setup/koji-setup/bootstrap-build.sh $TOPDIR/koji-jenkins-setup/run-scripts2
  docker run -d --rm --name koji-client \
             --volume $KOJI_CONFIG:/opt/koji-clients \
             --volume $TOPDIR/koji-jenkins-setup/run-scripts2:/root/run-scripts \
             --volume /builds/centos7/release/centos-7.6:/builds \
	     --add-host="gitcentos.mvista.com:$HOST_IP" \
	     --add-host="centos7mirror.mvista.com:$HOST_IP" \
             -e HOST=$HOST \
             -e KOJI_MOCK=$KOJI_MOCK \
             -e KOJI_SCMS=$KOJI_SCMS \
             -t $IMAGE_KOJI_CLIENT
  sleep 5
  docker exec -it koji-client koji moshimoshi
  docker exec -it koji-client bash /root/run-scripts/bootstrap-build.sh
  docker exec -it koji-client bash /root/run-scripts/package-add.sh
  docker exec -it koji-client koji grant-permission repo user

  docker stop koji-client
   
  
}
startup_koji_builder () {
  if [ ! -d "$KOJI_MOCK" ]; then
    mkdir -p $KOJI_MOCK
  fi
  docker stack deploy --compose-file $SCRIPT_DIR/builder-compose.yml  $STACK_KOJI
  sleep 20
}
startup_jenkins_container() {
  echo $JENKINS_HOME
  USERDIR=$KOJI_CONFIG/user
  if [ ! -d $KOJI_CONFIG/user ] ; then
    USERDIR=$KOJI_CONFIG/users/user
  fi
  sudo mkdir -p $JENKINS_HOME/.koji/
  sudo cp -a $USERDIR/* $JENKINS_HOME/.koji/
  cat > $TOPDIR/config <<- EOF
[koji]
server = http://${HOST}/kojihub
weburl = http://${HOST}/koji
topurl = http://${HOST}/kojifiles
cert = ~/.koji/client.crt
ca = ~/.koji/clientca.crt
serverca = ~/.koji/serverca.crt
authtype = ssl
anon_retry = true
EOF
  sudo mv -f $TOPDIR/config $JENKINS_HOME/.koji/
  cp -a $TOPDIR/koji-jenkins-setup/jenkins/plugins.txt $TOPDIR/koji-jenkins-setup/jenkins/init/* $JENKINS_HOME
  sudo chown $JENKINS_UID.$JENKINS_UID -R $JENKINS_HOME
  env | grep BRANCH
  docker stack deploy --compose-file $SCRIPT_DIR/jenkins-compose.yml  $STACK_KOJI
  sleep 10
}

rm_existing_docker_stack
prepare_working_directory
create_nginx_default_conf
prepare_koji_hub_container_setup
prepare_jenkins_container_setup
pull_docker_images
startup_koji_hub
startup_koji_builder
bootstrap_build_in_koji_client_container
startup_jenkins_container
