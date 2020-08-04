terraform {
  backend "s3" {
    bucket = "tyk-api-gateway-tfstate"
    key = "tfstate"
    region = "us-west-2"
  }
}


variable "name" {
  default = "tyk-api-gateway"
}

variable "app_hostnames" {
  type = list(string)
  default = [ "dummy0", "dummy1", ]
}


provider "aws" {
  region  = "us-west-2"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks.token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.eks.token
    load_config_file       = false
  }
}


data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_id
}

resource "aws_ecr_repository" "eks_app" {
  for_each = { for v in var.app_hostnames : v => v }

  name = var.name
  tags = { Name = var.name }
}

resource "aws_s3_bucket" "charts" {
  bucket = var.name
  acl = "public"

  versioning {
    enabled = true
  }

  tags = merge( { Name = var.name }, { App = "helm" } )
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 2.38.0"
  name                   = var.name
  cidr                   = "10.16.0.0/16"
  azs                    = data.aws_availability_zones.available
  private_subnets        = [ "10.16.0.0/24", "10.16.1.0/24", ]
  public_subnets         = [ "10.16.2.0/24", "10.16.3.0/24", ]
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true

  tags = { Name = var.name }

  public_subnet_tags = {
    "kubernetes.io/cluster/${ var.name }" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${ var.name }" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 12.0"

  cluster_name = var.name
  subnets      = module.vpc.private_subnets

  tags = { Name = var.name }

  vpc_id = module.vpc.vpc_id

  worker_groups = [
    {
      name                          = var.name
      instance_type                 = "t2.medium"
      asg_min_size                  = 0
      asg_max_size                  = 2
      asg_desired_capacity          = 1
    },
  ]

  worker_additional_security_group_ids = aws_security_group.workers.id

  cluster_endpoint_private_access  = true
  cluster_endpoint_public_access   = true

}

resource "aws_security_group" "workers" {
  name = var.name
  vpc_id = module.vpc.vpc_id

  ingress {}
}

resource "helm_release" "tyk_ingress" {
  name = var.name
  chart = "tyk-ingress"
  namespace = "tyk-ingress"
  create_namespace = true

  values = [ <<EOF
    # Default values for tyk-dashboard.
    # This is a YAML-formatted file.
    # Declare variables to be passed into your templates.
    
    nameOverride: ""
    fullnameOverride: ""
    
    # Only set this to false if you are not planning on using the sidecar injector
    enableSharding: true
    
    secrets:
      APISecret: "CHANGEME"
      AdminSecret: "12345"
    
    redis:
        shardCount: 128
        host: "tyk-redis-master.tyk-ingress.svc.cluster.local"
        port: 6379
        useSSL: false
        pass: ""
    
    mongo:
        mongoURL: "mongodb://root:pass@tyk-mongo-mongodb.tyk-ingress.svc.cluster.local:27017/tyk-dashboard?authSource=admin"
        useSSL: false
    
    mdcb:
      enabled: false
      useSSL: false
      replicaCount: 1
      containerPort: 9090
      healthcheckport: 8181
      license: ""
      forwardAnalyticsToPump: true
      image:
        repository: tykio/tyk-mdcb-docker #requires credential
        tag: latest
        pullPolicy: Always
      service:
        type: LoadBalancer
        port: 9090
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations: []
      affinity: {}
      extraEnvs: []
    
    
    tib:
      enabled: false
      useSSL: true
      replicaCount: 1
      containerPort: 3010
      image:
        repository: tykio/tyk-identity-broker
        tag: latest
        pullPolicy: Always
      service:
        type: ClusterIP
        port: 3010
      ingress:
        enabled: false
        annotations: {}
          # kubernetes.io/ingress.class: nginx
          # kubernetes.io/tls-acme: "true"
        path: /
        hosts:
          - tib.local
        tls: []
        #  - secretName: chart-example-tls
        #    hosts:
        #      - chart-example.local
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations: []
      affinity: {}
      extraEnvs: []
      configMap:
        #Create a configMap to store profiles json
        profiles: tyk-tib-profiles-conf
    
    dash:
      replicaCount: 1
      hostName: "localhost"
      license: ""
      containerPort: 3000
      image:
        repository: tykio/tyk-dashboard
        tag: latest
        pullPolicy: Always
      service:
        type: LoadBalancer
        port: 3000
      ingress:
        enabled: false
        annotations: {}
          # kubernetes.io/ingress.class: nginx
          # kubernetes.io/tls-acme: "true"
        path: /
        hosts:
          - tyk-dashboard.local
        tls: []
        #  - secretName: chart-example-tls
        #    hosts:
        #      - chart-example.local
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations: []
      affinity: {}
      extraEnvs: []
    
    portal:
      ingress:
        enabled: false
        annotations: {}
          # kubernetes.io/ingress.class: nginx
          # kubernetes.io/tls-acme: "true"
        path: /
        hosts:
          - tyk-portal.local
        tls: []
        #  - secretName: chart-example-tls
        #    hosts:
        #      - chart-example.local
    
    gateway:
      kind: DaemonSet
      replicaCount: 2
      hostName: "gateway.tykbeta.com"
      tags: "ingress"
      tls: true
      containerPort: 8080
      image:
        repository: tykio/tyk-gateway
        tag: latest
        pullPolicy: Always
      service:
        type: LoadBalancer
        port: 443
        externalTrafficPolicy: Local
        annotations: {}
      ingress:
        enabled: false
        annotations: {}
          # kubernetes.io/ingress.class: nginx
          # kubernetes.io/tls-acme: "true"
        path: /
        hosts:
          - tyk-gw.local
        tls: []
        #  - secretName: chart-example-tls
        #    hosts:
        #      - chart-example.local
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations:
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      affinity: {}
      extraEnvs: []
    
    pump:
      replicaCount: 1
      image:
        repository: tykio/tyk-pump-docker-pub
        tag: latest
        pullPolicy: Always
      annotations: {}
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations: []
      affinity: {}
      extraEnvs: []
    
    rbac: true 
    tyk_k8s:
      replicaCount: 1
      image:
        repository: tykio/tyk-k8s
        tag: latest
        pullPolicy: Always
      serviceMesh:
        enabled: false
      watchNamespaces: []
      resources: {}
        # We usually recommend not to specify default resources and to leave this as a conscious
        # choice for the user. This also increases chances charts run on environments with little
        # resources, such as Minikube. If you do want to specify resources, uncomment the following
        # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
        # limits:
        #  cpu: 100m
        #  memory: 128Mi
        # requests:
        #  cpu: 100m
        #  memory: 128Mi
      nodeSelector: {}
      tolerations: []
      affinity: {}

    EOF
  ]
}
