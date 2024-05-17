provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "minikube"
  }
}

resource "null_resource" "start_minikube" {
  provisioner "local-exec" {
    command = "minikube start"
  }
}

resource "null_resource" "wait_for_minikube" {
  provisioner "local-exec" {
    command = <<-EOT
      for i in {1..30}; do
        if kubectl get nodes &> /dev/null; then
          exit 0
        fi
        sleep 10
      done
      echo "Kubernetes cluster is not reachable" >&2
      exit 1
      EOT
    interpreter = ["bash", "-c"]
  }
  depends_on = [null_resource.start_minikube]
}

resource "null_resource" "delete_existing_release" {
  provisioner "local-exec" {
    command = <<-EOT
      if helm list -q | grep 'redis-deployment'; then
        helm uninstall redis-deployment
      else
        echo "No existing release to delete"
      fi
      EOT
    interpreter = ["bash", "-c"]
  }
  depends_on = [null_resource.wait_for_minikube]
}

resource "local_file" "helm_chart_directory" {
  filename = "${path.module}/redis-helmchart/templates/deployment.yaml"
  content  = <<-EOT
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
spec:
  replicas: {{ .Values.redis.replicaCount }}
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: "{{ .Values.redis.image.repository }}:{{ .Values.redis.image.tag }}"
        imagePullPolicy: {{ .Values.redis.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.redis.service.port }}
  EOT
}

resource "local_file" "helm_chart_values" {
  filename = "${path.module}/redis-helmchart/values.yaml"
  content  = <<-EOT
redis:
  replicaCount: 1
  image:
    repository: redis
    tag: latest
    pullPolicy: IfNotPresent
  service:
    port: 6379
  EOT
}

resource "local_file" "helm_chart_yaml" {
  filename = "${path.module}/redis-helmchart/Chart.yaml"
  content  = <<-EOT
name: redis
version: 0.1.0
description: A Helm chart for deploying a Redis server.
  EOT
}

resource "null_resource" "initialize_helm_chart_directory" {
  provisioner "local-exec" {
    command = <<-EOT
      if [ ! -d "redis-helmchart/templates" ]; then
        mkdir -p redis-helmchart/templates
      fi
      EOT
    interpreter = ["bash", "-c"]
  }
}

resource "helm_release" "custom_redis_deployment" {
  name       = "redis-deployment"
  repository = "./redis-helmchart"
  chart      = "."
  depends_on = [
    null_resource.delete_existing_release,
    local_file.helm_chart_directory,
    local_file.helm_chart_values,
    local_file.helm_chart_yaml,
    null_resource.initialize_helm_chart_directory
  ]
}

resource "null_resource" "set_redis_key" {
  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -x
      export POD_NAME=$(kubectl get pods --namespace=default --selector=app=redis -o jsonpath='{.items[0].metadata.name}')
      echo $POD_NAME
      kubectl exec $POD_NAME -- redis-cli SET OxKey OxValue
      EOT
    interpreter = ["bash", "-c"]
  }
  depends_on = [helm_release.custom_redis_deployment]
}

resource "null_resource" "get_redis_value" {
  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -x
      export POD_NAME=$(kubectl get pods --namespace=default --selector=app=redis -o jsonpath='{.items[0].metadata.name}')
      echo $POD_NAME
      kubectl exec $POD_NAME -- redis-cli GET OxKey
      EOT
    interpreter = ["bash", "-c"]
  }
  depends_on = [null_resource.set_redis_key]
}
