locals {
  haxelib_server = {
    stage = {
      dev = {
        host    = "development-lib.haxe.org"
        host_do = "do-development-lib.haxe.org"
        image   = var.HAXELIB_SERVER_IMAGE_DEVELOPMENT != null ? var.HAXELIB_SERVER_IMAGE_DEVELOPMENT : try(data.terraform_remote_state.previous.outputs.haxelib_server.stage.dev.image, null)
      }
      prod = {
        host    = "lib.haxe.org"
        host_do = "do-lib.haxe.org"
        image   = var.HAXELIB_SERVER_IMAGE_MASTER != null ? var.HAXELIB_SERVER_IMAGE_MASTER : try(data.terraform_remote_state.previous.outputs.haxelib_server.stage.prod.image, null)
      }
    }
  }
}

output "haxelib_server" {
  value = local.haxelib_server
}

resource "kubernetes_secret_v1" "do-haxelib-minio-s3fs-config" {
  provider = kubernetes.do

  metadata {
    name = "haxelib-minio-s3fs-config"
  }

  data = {
    "passwd" = "${data.kubernetes_secret.haxelib-server-do-spaces.data.SPACES_ACCESS_KEY_ID}:${data.kubernetes_secret.haxelib-server-do-spaces.data.SPACES_SECRET_ACCESS_KEY}"
  }
}

# kubectl create secret generic rds-mysql-haxelib --from-literal=user=FIXME --from-literal=password=FIXME
data "kubernetes_secret" "do-rds-mysql-haxelib" {
  provider = kubernetes.do
  metadata {
    name = "rds-mysql-haxelib"
  }
}

resource "kubernetes_deployment" "do-haxelib-server" {
  for_each = local.haxelib_server.stage

  provider = kubernetes.do
  metadata {
    name = "haxelib-server-${each.key}"
    labels = {
      "app.kubernetes.io/name"     = "haxelib-server"
      "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "haxelib-server"
        "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "haxelib-server"
          "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
        }
      }

      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
            }
          }
        }
        # affinity {
        #   node_affinity {
        #     preferred_during_scheduling_ignored_during_execution {
        #       preference {
        #         match_expressions {
        #           key      = "node.kubernetes.io/instance-type"
        #           operator = "In"
        #           values   = ["s-4vcpu-8gb"]
        #         }
        #       }
        #       weight = 1
        #     }
        #   }
        # }

        container {
          image = each.value.image
          name  = "haxelib-server"

          port {
            container_port = 80
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "200Mi"
            }
            limits = {
              memory = "2.5Gi"
            }
          }

          env {
            name  = "HAXELIB_DB_HOST"
            value = "haxelib-mysql-57-primary"
          }
          env {
            name  = "HAXELIB_DB_PORT"
            value = "3306"
          }
          env {
            name  = "HAXELIB_DB_NAME"
            value = "haxelib"
          }
          env {
            name  = "HAXELIB_DB_USER"
            value = "haxelib"
          }
          env {
            name = "HAXELIB_DB_PASS"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret_v1.haxelib-mysql-57.metadata[0].name
                key  = "mysql-password"
              }
            }
          }

          env {
            name  = "HAXELIB_CDN"
            value = digitalocean_cdn.haxelib.endpoint
          }

          env {
            name  = "HAXELIB_S3BUCKET"
            value = digitalocean_spaces_bucket.haxelib.name
          }
          env {
            name  = "HAXELIB_S3BUCKET_ENDPOINT"
            value = "${digitalocean_spaces_bucket.haxelib.region}.digitaloceanspaces.com"
          }
          env {
            name = "HAXELIB_S3BUCKET_MOUNTED_PATH"
            value = "/var/haxelib-s3fs"
          }

          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = "haxelib-server-do-spaces"
                key  = "SPACES_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = "haxelib-server-do-spaces"
                key  = "SPACES_SECRET_ACCESS_KEY"
              }
            }
          }
          env {
            name  = "AWS_DEFAULT_REGION"
            value = "us-east-1"
          }

          volume_mount {
            name       = "pod-haxelib-s3fs"
            mount_path = "/var/haxelib-s3fs"
            mount_propagation = "HostToContainer"
            read_only  = false
          }

          liveness_probe {
            http_get {
              path = "/httpd-status?auto"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 15
            timeout_seconds       = 5
          }
        }

        container {
          image = "haxe/s3fs:latest"
          name  = "s3fs"
          command = [
            "s3fs", digitalocean_spaces_bucket.haxelib.name, "/var/s3fs",
            "-f",
            "-o", "url=http://${kubernetes_service_v1.do-haxelib-minio.metadata[0].name}:9000",
            "-o", "use_path_request_style",
            "-o", "umask=022,uid=33,gid=33", # 33 = www-data
            "-o", "allow_other",
          ]

          security_context {
            privileged = true
          }

          resources {
            requests = {
              cpu    = "0.1"
              memory = "50Mi"
            }
          }

          env {
            name = "AWSACCESSKEYID"
            value_from {
              secret_key_ref {
                name = "haxelib-server-do-spaces"
                key  = "SPACES_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "AWSSECRETACCESSKEY"
            value_from {
              secret_key_ref {
                name = "haxelib-server-do-spaces"
                key  = "SPACES_SECRET_ACCESS_KEY"
              }
            }
          }

          volume_mount {
            name       = "pod-haxelib-s3fs"
            mount_path = "/var/s3fs"
            mount_propagation = "Bidirectional"
            read_only  = false
          }
        }

        security_context {
          fs_group = 33 # www-data
        }

        volume {
          name = "pod-haxelib-s3fs"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget" "do-haxelib-server" {
  for_each = local.haxelib_server.stage

  provider = kubernetes.do
  metadata {
    name = "haxelib-server-${each.key}"
  }
  spec {
    min_available = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "haxelib-server"
        "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
      }
    }
  }
}

resource "kubernetes_service" "do-haxelib-server" {
  for_each = local.haxelib_server.stage

  provider = kubernetes.do
  metadata {
    name = "haxelib-server-${each.key}"
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = "haxelib-server"
      "app.kubernetes.io/instance" = "haxelib-server-${each.key}"
    }

    port {
      name     = "http"
      protocol = "TCP"
      port     = 80
    }
  }
}

resource "kubernetes_ingress_v1" "do-haxelib-server" {
  for_each = local.haxelib_server.stage

  provider = kubernetes.do
  metadata {
    name = "haxelib-server-${each.key}"
    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-production"

      # Do not force https at ingress-level.
      # Let the Apache in the haxelib server container handle it.
      "nginx.ingress.kubernetes.io/ssl-redirect" = false

      # https://nginx.org/en/docs/http/ngx_http_proxy_module.html
      "nginx.ingress.kubernetes.io/proxy-buffering"       = "on"
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOT
        proxy_set_header Cookie "";
        proxy_cache mycache;
        proxy_cache_key "$scheme$request_method$host$request_uri";
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_revalidate on;
        proxy_cache_lock on;
        add_header X-Cache-Status $upstream_cache_status;
      EOT
    }
  }

  spec {
    tls {
      hosts       = [each.value.host_do, each.value.host]
      secret_name = "haxelib-server-${each.key}-tls"
    }
    rule {
      host = each.value.host_do
      http {
        path {
          backend {
            service {
              name = kubernetes_service.do-haxelib-server[each.key].metadata[0].name
              port {
                number = 80
              }
            }
          }
          path = "/"
        }
      }
    }
    rule {
      host = each.value.host
      http {
        path {
          backend {
            service {
              name = kubernetes_service.do-haxelib-server[each.key].metadata[0].name
              port {
                number = 80
              }
            }
          }
          path = "/"
        }
      }
    }
  }
}
