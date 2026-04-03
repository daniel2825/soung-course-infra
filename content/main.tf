# --- 0. Configuración Centralizada ---
locals {
  # BUSCA ESTOS NOMBRES EN TU ARCHIVO amplify_outputs.json
  amplify_bucket_name = "amplify-d1q7yw091jwae4-ma-songcoursecontentbucketc-0naz9if3cy8t" 
  amplify_table_name  = "SongCourseContent-uvelwqazbzg6fciansiablhufq-NONE" # Nombre real en la consola de AWS
  
  # Carga de datos del JSON
  json_data = jsondecode(file("${path.module}/cursos.json"))
  courses_map = { for course in local.json_data : course.id_course => course }
}

# --- 1. Referencias a Recursos Existentes (Amplify) ---
data "aws_s3_bucket" "amplify_assets" {
  bucket = local.amplify_bucket_name
}

data "aws_dynamodb_table" "amplify_table" {
  name = local.amplify_table_name
}

# --- 2. Sincronización de Archivos (Fast Sync) ---
resource "null_resource" "upload_to_s3" {
  triggers = {
    file_hashes = md5(join("", [for f in fileset("${path.module}/upload", "**") : filemd5("${path.module}/upload/${f}")]))
  }

  provisioner "local-exec" {
    # Usamos el ID del bucket que encontró Amplify
    command = "aws s3 sync ${path.module}/upload/ s3://${data.aws_s3_bucket.amplify_assets.id}/ --delete"
  }
}

# --- 3. Carga de Datos en la Tabla de Amplify ---
resource "aws_dynamodb_table_item" "course_items" {
  for_each = local.courses_map

  # Usamos el nombre de la tabla que encontró Amplify
  table_name = data.aws_dynamodb_table.amplify_table.name
  hash_key   = data.aws_dynamodb_table.amplify_table.hash_key

  item = jsonencode({
    "id"    = { S = each.value.id_course }
    "title"        = { S = each.value.title }
    "banner_image" = { S = each.value.banner_image }
    "videos" = {
      L = [
        for v in each.value.videos : {
          M = {
            "module_number" : { S = v.module_number },
            "module_title"  : { S = v.module_title },
            "banner_video"  : { S = v.banner_video }
          }
        }
      ]
    }
  })

  # Garantiza que el video esté en S3 antes de aparecer en la DB
  depends_on = [null_resource.upload_to_s3]
}