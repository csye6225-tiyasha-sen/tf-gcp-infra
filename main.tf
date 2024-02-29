terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
}

provider "google" {
  credentials = file(var.credentials)
  project     = var.project
  region      = var.region
  zone        = var.zone

}


resource "google_compute_network" "vpc_network" {
  for_each                        = { for idx, name in var.vpc_names : name => idx }
  name                            = each.key
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}


resource "google_compute_subnetwork" "subnet_webapp" {
  for_each      = google_compute_network.vpc_network
  name          = "${var.subnetwebapp-name}-${each.value.name}"
  network       = each.value.name
  ip_cidr_range = var.ip-cidr-range-subnetwebapp
  region        = var.region
}

resource "google_compute_subnetwork" "subnet_db" {
  for_each      = google_compute_network.vpc_network
  name          = "${var.subnetdb-name}-${each.value.name}"
  network       = each.value.name
  ip_cidr_range = var.ip-cidr-range-subnetdb
  region        = var.region
}

resource "google_compute_route" "webapp-route" {
  for_each         = google_compute_network.vpc_network
  name             = "${var.webapp-route-name}-${each.value.name}"
  dest_range       = var.dest-range
  network          = each.value.name
  next_hop_gateway = var.hop_gateway
  priority         = var.webapp-route-priority

}



resource "google_compute_firewall" "rules" {
  for_each      = google_compute_network.vpc_network
  name          = "${var.firewall-name}-${each.value.name}"
  network       = each.value.name
  source_ranges = [var.sources_ranges]
  description   = var.descriptioninstance

  allow {
    protocol = var.protocol
    ports    = [var.port-number]
  }

  #add deny port in new firewall

  target_tags = [var.target-tag]
}

resource "google_compute_instance" "devinstance" {
  for_each     = google_compute_subnetwork.subnet_webapp
  name         = var.instancename
  machine_type = var.machine_type
  zone         = var.zone
  tags         = var.target-taginstance

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.imagename
      size  = var.initialize_params_size
      type  = var.initialize_params_type
    }

    mode = var.mode
  }
  network_interface {
    access_config {
      network_tier = var.network_tier
    }

    queue_count = var.queuecount
    stack_type  = var.stack_type
    subnetwork  = each.value.name
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = var.on_host_maintenance
    preemptible         = false
    provisioning_model  = var.provisioning_model
  }

  metadata_startup_script = templatefile("./scripts/startup-script.sh", {
    psql_username = var.sql_user_name
    psql_password = random_password.password.result
    psql_database = google_sql_database.database[each.key].name
    psql_hostname = google_sql_database_instance.mainpostgres[each.key].private_ip_address
  })

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

}
resource "google_compute_global_address" "private_ip_address" {
  for_each      = google_compute_network.vpc_network
  name          = var.global_address_name
  purpose       = var.global_address_purpose
  address_type  = var.address_type
  prefix_length = var.prefix_length_ip
  network       = each.value.name

}
resource "google_service_networking_connection" "servicenetworking" {
  for_each                = google_compute_network.vpc_network
  network                 = each.value.name
  service                 = var.networking_service
  reserved_peering_ranges = [google_compute_global_address.private_ip_address[each.key].name]
}

resource "google_sql_database_instance" "mainpostgres" {
  for_each            = google_compute_network.vpc_network
  name                = var.sqlinstance_name
  database_version    = var.database_version
  region              = var.region
  deletion_protection = false
  depends_on          = [google_service_networking_connection.servicenetworking]

  settings {
    tier = var.tier

    ip_configuration {

      ipv4_enabled    = false
      private_network = each.value.id

    }

    availability_type = var.availability_type
    disk_type         = var.disk_type
    disk_size         = var.disk_size
  }

}

resource "google_sql_database" "database" {
  for_each = google_sql_database_instance.mainpostgres
  name     = var.database_name
  instance = each.value.id
}

resource "random_password" "password" {
  length           = var.password_length
  special          = true
  override_special = var.override_special
}

#users
resource "google_sql_user" "users" {
  for_each = google_sql_database_instance.mainpostgres
  name     = var.sql_user_name
  instance = each.value.id
  password = random_password.password.result
}
