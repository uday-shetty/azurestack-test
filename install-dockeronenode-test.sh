#!/bin/bash
# 1ST SECTION - CAPTURE ARGUMENTS FROM ARM TEMPLATE AS VARIABLES

UCP_PUBLIC_FQDN=$1
echo "UCP_PUBLIC_FQDN: $UCP_PUBLIC_FQDN"
DTR_PUBLIC_FQDN=$2
echo "DTR_PUBLIC_FQDN: $DTR_PUBLIC_FQDN"
UCP_ADMIN_PASSWORD=$3
echo "UCP_ADMIN_PASSWORD: $UCP_ADMIN_PASSWORD"
UCP_VERSION=$4
echo "UCP_VERSION: $UCP_VERSION"
DTR_VERSION=$5
echo "DTR_VERSION: $DTR_VERSION"
DOCKER_VERSION=$6
echo "DOCKER_VERSION: $DOCKER_VERSION"
DOCKER_EE_URL=$7
echo "DOCKER_EE_URL: $DOCKER_EE_URL"
DOCKER_LICENSE=$8
echo "DOCKER_LICENSE: $DOCKER_LICENSE"
APP_ELB_HOSTNAME=$9
echo "APP_ELB_HOSTNAME: $APP_ELB_HOSTNAME"
PRIVATE_IP=${10}
echo "PRIVATE_IP: $PRIVATE_IP"

PRODUCTION_UCP_ORG='docker'
UCP_ORG=${UCP_ORG:-"docker"}
UCP_IMAGE=${UCP_ORG}/ucp:${UCP_VERSION}
DTR_ORG=${DTR_ORG:-"docker"}
DTR_IMAGE=${DTR_ORG}/dtr:${DTR_VERSION}
IMAGE_LIST_ARGS=''


# 2ND SECTION - CHECK VARIABLES EXIST

if [ -z "$UCP_PUBLIC_FQDN" ]; then
    echo 'UCP_PUBLIC_FQDN is undefined'
    exit 1
fi

if [ -z "$UCP_ADMIN_PASSWORD" ]; then
    echo 'UCP_ADMIN_PASSWORD is undefined'
    exit 1
fi

if [ -z "$DTR_PUBLIC_FQDN" ]; then
    echo 'DTR_PUBLIC_FQDN is undefined'
    exit 1
fi

if [ -z "$DOCKER_EE_URL" ]; then
    echo 'DOCKER_EE_URL is undefined'
    exit 1
fi



# 3RD SECTION - INSTALL DOCKER EE

apt-get -y install jq
apt-get update
apt-get install dialog apt-utils
apt-get install -y --no-install-recommends \
    linux-image-extra-$(uname -r) \
    linux-image-extra-virtual \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
curl -fsSL $DOCKER_EE_URL/ubuntu/gpg | apt-key add -

# create the long-life config file
echo "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee /etc/sysctl.d/99-my-disable-ipv6.conf

# ask the system to use it
sudo service procps reload

# check the result
cat /proc/sys/net/ipv6/conf/all/disable_ipv6

add-apt-repository \
   "deb [arch=amd64] $DOCKER_EE_URL/ubuntu \
   $(lsb_release -cs) \
   stable-$DOCKER_VERSION"
apt-get update
apt-get install -y docker-ee

service docker restart
sleep 10

# 4TH SECTION - run meta container
docker run \
  --label com.docker.editions.system \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --name=meta-azure \
  --restart=always \
  -d \
  -p $PRIVATE_IP:9024:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ushetty/meta-azure:dev metaserver -iaas_provider=azure

# 5TH SECTION - INSTALL UCP

if [ "$DOCKER_LICENSE" != "" ]; then
    	LIC_FILE=/tmp/docker_subscription.lic
	echo -n  "$DOCKER_LICENSE" | base64 -d >> $LIC_FILE
	jq -e '.|{key_id}' $LIC_FILE >> /dev/null
       	if [[ $? -eq 0 ]]
        then
        	echo "valid license "
        else 
		echo "License input must be a valid JSON license key. Please upload license in UI after installation."
        fi
else
        echo "Unable to read license file. Please upload license in UI after installation."

fi


#Download Docker UCP images
images=$(docker run --rm $UCP_IMAGE images --list $IMAGE_LIST_ARGS)
for im in $images; do
    docker pull $im
done

#Download DTR images
images=$(docker run --rm $DTR_IMAGE images)
for im in $images; do
    docker pull $im
done

docker run --rm --name ucp \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/docker_subscription.lic:/config/docker_subscription.lic \
  docker/ucp:$UCP_VERSION \
  install --controller-port 443 --san $UCP_PUBLIC_FQDN --external-service-lb $APP_ELB_HOSTNAME --admin-password $UCP_ADMIN_PASSWORD

# Check if UCP is installed, if not sleep for 15
if [[ $(curl --insecure --silent --output /dev/null --write-out '%{http_code}' https://"$UCP_PUBLIC_FQDN"/_ping) -ne 200 ]];
then
	sleep 15
fi

/bin/rm -rf /tmp/docker_subscription.lic

# 6TH SECTION - INSTALL DTR

if [ -z "$UCP_NODE"]; then
  export UCP_NODE=$(docker node ls | grep mgr0 | awk '{print $3}');
fi


docker run --rm \
  docker/dtr:$DTR_VERSION install \
  --replica-http-port 12392 \
  --replica-https-port 12391 \
  --ucp-url $UCP_PUBLIC_FQDN \
  --ucp-node $UCP_NODE \
  --dtr-external-url $DTR_PUBLIC_FQDN \
  --ucp-username admin --ucp-password $UCP_ADMIN_PASSWORD \
  --ucp-insecure-tls 
