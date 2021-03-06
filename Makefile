ifneq (,$(wildcard ./.env))
    include .env
    export
endif

check-env:
ifndef k8s
	$(error Please update .env file and run make prereq)
endif

istio-check: prereq infra metallb deploy_istio deploy_app deploy_gw get_gw_ip test_app
tsb-check: infra tsb-infra deploy_app deploy_app_tsb tsb_test_app

prereq:
	@echo "istalling prereq...";
	@echo "installing getmesh...\n";
	@curl -sL https://istio.tetratelabs.io/getmesh/install.sh | bash


infra: check-env
	@echo "===========================";
	@echo "Creating k8s cluster...\n";
	minikube start \
	--kubernetes-version=${k8s} \
	--memory=${mem} \
	--cpus=${cpu} --driver=${driver} \
	--addons="metallb,metrics-server" -p ${clustername} \
	--insecure-registry $(registry);
	@sleep 10;

metallb:
	@echo "==========================="
	@echo "Getting the cluster IP and creating loadBalancer IP ranges...\n";
	$(eval metallbip :=$(shell infra/nextip.sh))
	@envsubst < infra/metallb-config.yaml | kubectl apply -f -;
	@echo "loadBalancer IP ranges configured...\n";	

tsb-infra: metallb
	tctl install image-sync --username $(username) --apikey $(apikey) --registry $(registry);
	tctl install demo --registry ${registry} --admin-password admin;
	@kubectl wait --for=condition=available --timeout=300s --all deployments -n istio-system;

deploy_istio: check-env
	@echo "===========================";
	@export PATH=$PATH:$HOME/.getmesh/bin/getmesh;
	@echo "installing istio...\n"
	@getmesh fetch --version=$(istio_version) --flavor=istio
	@getmesh istioctl install --set profile=$(istio_profile) -y
	@echo "waiting for istio...\n"
	@kubectl wait --for=condition=available --timeout=300s --all deployments -n istio-system;
	@sleep 60;

deploy_app:
	@echo "===========================";
	@echo "Deploying APP...\n";
	@kubectl apply -f app/;
	@echo;
	@echo "Waiting for APP...\n";
	@sleep 5;
	@kubectl wait --for=condition=available --timeout=300s --all deployments -n green;
	@kubectl wait --for=condition=available --timeout=300s --all deployments -n blue;

deploy_gw:
	@echo "===========================";
	@echo "Deploying gateway...\n";
	@kubectl apply -f istio/app-gateway.yaml;
	@echo
	@echo "Waiting for gateway...\n";	
	@sleep 15;

deploy_app_tsb:
	@echo "===========================";
	@echo "Creating TSB objects...\n";
	@kubectl apply -f tsb/ingress.yaml;
	@sleep 10;
	@tctl login --org tetrate --username admin --password 'admin' --tenant tetrate;
	@sleep 5;
	@tctl apply -f tsb/tenant.yaml;
	@tctl apply -f tsb/workspace.yaml;
	@tctl apply -f tsb/group.yaml;
	@tctl apply -f tsb/gateway.yaml;

get_gw_ip:
	$(eval ingress :=$(shell kubectl -n green get ingresses.networking.k8s.io --no-headers -o custom-columns=:metadata.name))
	@echo "===========================";
	@echo "Getting gateway IP...\n";
	@istio/waitforip.sh ${ingress} green

get_tsb_svc:
	@echo "===========================";
	@echo "Validating external IP...\n";
	$(eval gw :=$(shell kubectl -n green get svc -l platform.tsb.tetrate.io/plane=data --no-headers -o custom-columns=:metadata.name))
	@tsb/waitforip.sh ${gw} green
	@echo " ";
	-@echo "waiting for TSB resources to be deployed...\n"
	@sleep 60;

test_app:
	$(eval ingress :=$(shell kubectl -n green get ingresses.networking.k8s.io --no-headers -o custom-columns=:metadata.name))
	$(eval gwIP :=$(shell kubectl -n green get ingresses.networking.k8s.io ${ingress} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	@echo "===========================";
	@echo "Checking APP endpoints...\n";
	@echo "Checking prefix path http://${gwIP}/blue "
	@echo;
	@curl -s http://${gwIP}/blue --resolve "${hostname}:80:${gwIP}" | grep "Blue";
	@echo;
	@echo "Checking prefix path http://${gwIP}/green "
	@echo;
	@curl -s http://${gwIP}/green | grep "Green";

tsb_test_app: get_tsb_svc
	@echo "===========================";
	@echo "Validating APP routes...\n";
	$(eval gw :=$(shell kubectl -n green get svc -l platform.tsb.tetrate.io/plane=data --no-headers -o custom-columns=:metadata.name))
	$(eval vs :=$(shell kubectl -n green get virtualservice --no-headers -o custom-columns=:metadata.name))
	$(eval hostname :=$(shell kubectl -n green get virtualservice ${vs}  -o jsonpath='{.spec.hosts}' | tr -d '"[]"'))	
	$(eval gwIP :=$(shell kubectl -n green get service ${gw} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'))
	@echo "Checking prefix path http://${hostname}/blue \n"
	@curl -s http://${hostname}/blue --resolve "${hostname}:80:${gwIP}" | grep Blue;
	-@sleep 2;
	@echo;
	@echo "Checking prefix path http://${hostname}/green "
	@curl -s http://${hostname}/green --resolve "${hostname}:80:${gwIP}" | grep Green;

destroy: check-env
	minikube delete -p ${clustername}
