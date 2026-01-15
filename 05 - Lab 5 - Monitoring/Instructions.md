## Installing Prometheus and Grafana

Also for Prometheus we can use a Helm Chart

```shell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```
```shell
kubectl create ns monitoring
```

```shell
helm install -n monitoring prometheus prometheus-community/kube-prometheus-stack --set prometheus-node-exporter.hostRootFsMount.enabled=false --set grafana.defaultDashboardsTimezone=browser
```

https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

```shell
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Run query e.g. `apiserver_request_total`

```shell
kubectl port-forward svc/prometheus-grafana 3000:3000
```

user: admin  
password: 
```shell
kubectl -n monitoring get secrets prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```


## Import Dashboard

https://github.com/camunda/zeebe/blob/main/monitor/grafana/zeebe.json

--> Nothing to see yet

## Adjust Values

```
prometheusServiceMonitor:
  enabled: true
  labels:
    release: prometheus
  scrapeInterval: 10s
```

## Start

```shell
helm install camunda-platform camunda/camunda-platform -f camunda-platform-monitoring-values.yaml 
```

## Wait

```shell
kubectl get pods -w
```

## View Grafana Dasbhoard again

## Optimize

- Create Multi Process Report
- Discuss differences between monitoring the platform & monitoring processes

## Discussion
- How do participants normally monitor?
- Also Business Reporting?
