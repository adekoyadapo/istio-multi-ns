#!/usr/bin/env zsh
ip=""
while [ -z $ip ]; do
  echo "Waiting for external IP"
  ip=$(kubectl get svc $1 --namespace $2 --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
  [ -z "$ip" ] && sleep 10
done
echo 'Found external IP: '$ip