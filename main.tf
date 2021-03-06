/**
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  cfn_files = [
    "cfn/encrypter/function.go",
    "cfn/encrypter/go.mod",
  ]
  cfn_md5sums     = [for f in local.cfn_files : filemd5(f)]
  cfn_dirchecksum = md5(join("-", local.cfn_md5sums))
}

resource "google_project_service" "project_service" {
  for_each = toset([
    "iam.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
  ])
  project = var.project_id
  service = each.value
}

resource "google_storage_bucket" "cfn_bucket" {
  project       = var.project_id
  name          = "${var.project_id}-cfn-${var.function_name}"
  location      = "US"
  force_destroy = true
}

data "archive_file" "cfn" {
  type        = "zip"
  source_dir  = "cfn/encrypter"
  output_path = "cfn/build/${local.cfn_dirchecksum}.zip"
}

resource "google_storage_bucket_object" "archive" {
  name   = data.archive_file.cfn.output_path
  bucket = google_storage_bucket.cfn_bucket.name
  source = data.archive_file.cfn.output_path
}

resource "google_service_account" "gsa_encrypter" {
  project      = var.project_id
  account_id   = "cfn-${var.function_name}"
  display_name = "Cloud Function to generate and encrypt SA keys"
}

# NOTE: The Cloud Function will programmatically create keys
# and encrypt them. This may need to happen across projects
resource "google_organization_iam_member" "gsa_encrypter" {
  count  = var.use_org_level_permissions ? 1 : 0
  member = "serviceAccount:${google_service_account.gsa_encrypter.email}"
  role   = "roles/iam.serviceAccountKeyAdmin"
  org_id = var.org_id
}

resource "google_folder_iam_member" "gsa_encrypter" {
  count  = var.use_org_level_permissions ? 0 : 1
  member = "serviceAccount:${google_service_account.gsa_encrypter.email}"
  role   = "roles/iam.serviceAccountKeyAdmin"
  folder = var.folder_id
}

resource "google_cloudfunctions_function" "function" {
  project      = var.project_id
  region       = var.region
  name         = var.function_name
  description  = "Generates and encrypts a new Service Account key given a GPG public key"
  runtime      = "go113"
  trigger_http = true

  service_account_email = google_service_account.gsa_encrypter.email
  source_archive_bucket = google_storage_bucket.cfn_bucket.name
  source_archive_object = google_storage_bucket_object.archive.name
  entry_point           = "GenerateAndEncrypt"
  environment_variables = {
    PUBLIC_KEY = file(var.public_key_file)
  }

  depends_on = [google_project_service.project_service]
}

resource "google_cloudfunctions_function_iam_member" "invoker" {
  for_each       = toset(var.cfn_members)
  project        = var.project_id
  cloud_function = google_cloudfunctions_function.function.name

  role   = "roles/cloudfunctions.invoker"
  member = each.value
}

resource "local_file" "invoker" {
  filename        = "get-key"
  file_permission = "0755"
  content = templatefile("${path.module}/templates/get-key.tpl", {
    project  = var.project_id
    region   = var.region
    function = var.function_name
  })
}