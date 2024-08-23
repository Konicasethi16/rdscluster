locals {
  engine_mode = "provisioned"
  is_global   = var.global_cluster_identifier != ""

  db_engine_maj_vers_num      = join(".", slice(split(".", var.mysql_version), 0, 2))
  db_engine_maj_vers_complete = "mysql${local.db_engine_maj_vers_num}"
  parameter_group_db_family   = "aurora${local.db_engine_maj_vers_num == replace(local.db_engine_maj_vers_num, "5.6", "") ? "-${local.db_engine_maj_vers_complete}" : local.db_engine_maj_vers_num}"

  endpoints    = toset(compact([for key, value in var.instances : lookup(value, "custom_endpoint", null)]))
  endpointsmap = { for key, value in local.endpoints : key => compact([for ik, instance in aws_rds_cluster_instance.replicas : lookup(var.instances[ik], "custom_endpoint", null) == key ? instance.id : null]) }

  cluster_identifier = element(concat(aws_rds_cluster.this.*.id, aws_rds_cluster.snapshot.*.id, aws_rds_cluster.s3.*.id, aws_rds_cluster.pit_recovery.*.id, [""]), 0)

  s3_import = var.s3_import != null ? var.s3_import : {}

  s3_import_list = length(keys(local.s3_import)) == 0 ? [] : [var.s3_import]

  restore_to_point_in_time = var.restore_to_point_in_time != null ? var.restore_to_point_in_time : {}

  restore_to_point_in_time_list = length(keys(local.restore_to_point_in_time)) == 0 ? [] : [var.restore_to_point_in_time]
}


# module "instance_validation" {
#   source  = "rhythmictech/errorcheck/terraform"
#   version = "1.0.0"

#   assert        = length(var.instances) > 0
#   error_message = "he instances map value must have at least one item (e.g. instances ={\"1\" {instance_class = \"db.r5.large\"}})."
# }

# NOTE: use alias data source and target_key_arn per SYSTEMS-234
# https://github.com/terraform-providers/terraform-provider-aws/issues/3019
data "aws_kms_alias" "this" {
  count = var.storage_encrypted ? 1 : 0
  name  = "alias/${var.kms_key_alias}"
}

resource "aws_rds_cluster_parameter_group" "this" {
  count  = var.cluster_enabled ? 1 : 0
  name   = "${var.cluster_name}-cluster-parameter-group"
  family = local.parameter_group_db_family
  dynamic "parameter" {
    for_each = var.parameters
    content {
      apply_method = lookup(parameter.value, "apply_method", null)
      name         = parameter.value.name
      value        = parameter.value.value
    }
  }
  tags = var.tags
}

resource "aws_rds_cluster" "snapshot" {
  count = var.cluster_enabled && var.snapshot_identifier != "" ? 1 : 0

  # global
  global_cluster_identifier = var.global_cluster_identifier

  cluster_identifier = var.cluster_name

  replication_source_identifier = !var.is_primary && !local.is_global ? var.master_cluster_identifier : null
  source_region                 = !var.is_primary && var.storage_encrypted ? var.source_region : null # current region is source

  engine                      = var.aurora_engine
  engine_mode                 = local.engine_mode
  engine_version              = var.mysql_version
  db_subnet_group_name        = aws_db_subnet_group.this[0].id
  allow_major_version_upgrade = var.allow_major_version_upgrade

  # vpc_security_group_ids          = var.security_groups_ids
  vpc_security_group_ids          = local.sg_ids
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].id
  database_name                   = !var.is_primary && local.is_global ? null : var.database_name
  master_username                 = !var.is_primary && local.is_global ? null : var.admin_username
  master_password                 = !var.is_primary && local.is_global ? null : var.admin_password
  final_snapshot_identifier       = !var.is_primary ? null : "${var.cluster_name}-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  skip_final_snapshot             = var.skip_final_snapshot
  copy_tags_to_snapshot           = true
  backup_retention_period         = var.backup_retention_period
  tags                            = var.tags
  apply_immediately               = var.apply_immediately
  deletion_protection             = var.deletion_protection
  storage_encrypted               = var.storage_encrypted
  kms_key_id                      = var.storage_encrypted ? data.aws_kms_alias.this[0].target_key_arn : null
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  preferred_maintenance_window    = var.preferred_maintenance_window
  backtrack_window                = var.backtrack_window

  snapshot_identifier = var.snapshot_identifier

  #iam_authentication
  iam_database_authentication_enabled = var.iam_authentication_enabled

  iam_roles = var.iam_roles

  lifecycle {
    # Adding replication_source_identifier to avoid a plan diff (replication_source_identifier should be computed), https://github.com/hashicorp/terraform-provider-aws/issues/15643
    ignore_changes = [replication_source_identifier, final_snapshot_identifier, global_cluster_identifier, engine_version]
  }

  # Marking the null_resource as an explicit dependency
  # means this indirectly depends on everything the
  # null_resource depends on.
  depends_on = [null_resource.depends_on]
}

resource "aws_rds_cluster" "s3" {
  count = var.cluster_enabled && var.s3_import != null && local.s3_import != {} ? 1 : 0

  # global
  global_cluster_identifier = var.global_cluster_identifier

  cluster_identifier = var.cluster_name

  replication_source_identifier = !var.is_primary && !local.is_global ? var.master_cluster_identifier : null
  source_region                 = !var.is_primary && var.storage_encrypted ? var.source_region : null # current region is source

  engine                      = var.aurora_engine
  engine_mode                 = local.engine_mode
  engine_version              = var.mysql_version
  db_subnet_group_name        = aws_db_subnet_group.this[0].id
  allow_major_version_upgrade = var.allow_major_version_upgrade

  # vpc_security_group_ids          = var.security_groups_ids
  vpc_security_group_ids          = local.sg_ids
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].id
  database_name                   = !var.is_primary && local.is_global ? null : var.database_name
  master_username                 = !var.is_primary && local.is_global ? null : var.admin_username
  master_password                 = !var.is_primary && local.is_global ? null : var.admin_password
  final_snapshot_identifier       = !var.is_primary ? null : "${var.cluster_name}-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  skip_final_snapshot             = var.skip_final_snapshot
  copy_tags_to_snapshot           = true
  backup_retention_period         = var.backup_retention_period
  tags                            = var.tags
  apply_immediately               = var.apply_immediately
  deletion_protection             = var.deletion_protection
  storage_encrypted               = var.storage_encrypted
  kms_key_id                      = var.storage_encrypted ? data.aws_kms_alias.this[0].target_key_arn : null
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  preferred_maintenance_window    = var.preferred_maintenance_window
  backtrack_window                = var.backtrack_window

  #iam_authentication
  iam_database_authentication_enabled = var.iam_authentication_enabled

  iam_roles = var.iam_roles

  # S3 Import configuration
  dynamic "s3_import" {
    for_each = local.s3_import_list

    content {
      bucket_prefix         = lookup(s3_import.value, "bucket_prefix", null)
      source_engine         = lookup(s3_import.value, "source_engine", null)
      source_engine_version = lookup(s3_import.value, "source_engine_version", null)
      bucket_name           = lookup(s3_import.value, "bucket_name", null)
      ingestion_role        = lookup(s3_import.value, "ingestion_role", null)
    }
  }

  lifecycle {
    # Adding replication_source_identifier to avoid a plan diff (replication_source_identifier should be computed), https://github.com/hashicorp/terraform-provider-aws/issues/15643
    ignore_changes = [replication_source_identifier, final_snapshot_identifier, global_cluster_identifier, engine_version]
  }

  # Marking the null_resource as an explicit dependency
  # means this indirectly depends on everything the
  # null_resource depends on.
  depends_on = [null_resource.depends_on]
}

resource "aws_rds_cluster" "pit_recovery" {
  count = var.cluster_enabled && var.restore_to_point_in_time != null && local.restore_to_point_in_time != {} ? 1 : 0

  # global
  global_cluster_identifier = var.global_cluster_identifier

  cluster_identifier = var.cluster_name

  replication_source_identifier = !var.is_primary && !local.is_global ? var.master_cluster_identifier : null
  source_region                 = !var.is_primary && var.storage_encrypted ? var.source_region : null # current region is source

  engine                      = var.aurora_engine
  engine_mode                 = local.engine_mode
  engine_version              = var.mysql_version
  db_subnet_group_name        = aws_db_subnet_group.this[0].id
  allow_major_version_upgrade = var.allow_major_version_upgrade

  # vpc_security_group_ids          = var.security_groups_ids
  vpc_security_group_ids          = local.sg_ids
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].id
  database_name                   = !var.is_primary && local.is_global ? null : var.database_name
  master_username                 = !var.is_primary && local.is_global ? null : var.admin_username
  master_password                 = !var.is_primary && local.is_global ? null : var.admin_password
  final_snapshot_identifier       = !var.is_primary ? null : "${var.cluster_name}-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  skip_final_snapshot             = var.skip_final_snapshot
  copy_tags_to_snapshot           = true
  backup_retention_period         = var.backup_retention_period
  tags                            = var.tags
  apply_immediately               = var.apply_immediately
  deletion_protection             = var.deletion_protection
  storage_encrypted               = var.storage_encrypted
  kms_key_id                      = var.storage_encrypted ? data.aws_kms_alias.this[0].target_key_arn : null
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  preferred_maintenance_window    = var.preferred_maintenance_window
  backtrack_window                = var.backtrack_window

  dynamic "restore_to_point_in_time" {
    for_each = local.restore_to_point_in_time_list

    content {
      source_cluster_identifier  = lookup(restore_to_point_in_time.value, "source_cluster_identifier", null)
      restore_type               = lookup(restore_to_point_in_time.value, "restore_type", null)
      use_latest_restorable_time = lookup(restore_to_point_in_time.value, "use_latest_restorable_time", null)
      restore_to_time            = lookup(restore_to_point_in_time.value, "restore_to_time", null)
    }
  }

  #iam_authentication
  iam_database_authentication_enabled = var.iam_authentication_enabled

  iam_roles = var.iam_roles

  lifecycle {
    # Adding replication_source_identifier to avoid a plan diff (replication_source_identifier should be computed), https://github.com/hashicorp/terraform-provider-aws/issues/15643
    ignore_changes = [replication_source_identifier, final_snapshot_identifier, global_cluster_identifier, engine_version]
  }

  # Marking the null_resource as an explicit dependency
  # means this indirectly depends on everything the
  # null_resource depends on.
  depends_on = [null_resource.depends_on]
}

resource "aws_rds_cluster" "this" {
  count = var.cluster_enabled && var.snapshot_identifier == "" && local.s3_import == {} && local.restore_to_point_in_time == {} ? 1 : 0

  # global
  global_cluster_identifier = var.global_cluster_identifier

  cluster_identifier = var.cluster_name

  replication_source_identifier = !var.is_primary && !local.is_global ? var.master_cluster_identifier : null
  source_region                 = !var.is_primary && var.storage_encrypted ? var.source_region : null # current region is source

  engine               = var.aurora_engine
  engine_mode          = local.engine_mode
  engine_version       = var.mysql_version
  db_subnet_group_name = aws_db_subnet_group.this[0].id

  # vpc_security_group_ids          = var.security_groups_ids
  vpc_security_group_ids          = local.sg_ids
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].id
  database_name                   = !var.is_primary && local.is_global ? null : var.database_name
  master_username                 = !var.is_primary && local.is_global ? null : var.admin_username
  master_password                 = !var.is_primary && local.is_global ? null : var.admin_password
  final_snapshot_identifier       = !var.is_primary ? null : "${var.cluster_name}-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  skip_final_snapshot             = var.skip_final_snapshot
  copy_tags_to_snapshot           = true
  backup_retention_period         = var.backup_retention_period
  tags                            = var.tags
  apply_immediately               = var.apply_immediately
  deletion_protection             = var.deletion_protection
  storage_encrypted               = var.storage_encrypted
  kms_key_id                      = var.storage_encrypted ? data.aws_kms_alias.this[0].target_key_arn : null
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  backtrack_window                = var.backtrack_window

  #iam_authentication
  iam_database_authentication_enabled = var.iam_authentication_enabled

  iam_roles = var.iam_roles

  lifecycle {
    # Adding replication_source_identifier to avoid a plan diff (replication_source_identifier should be computed), https://github.com/hashicorp/terraform-provider-aws/issues/15643
    ignore_changes = [replication_source_identifier, final_snapshot_identifier, engine_version]
  }

  # Marking the null_resource as an explicit dependency
  # means this indirectly depends on everything the
  # null_resource depends on.
  depends_on = [null_resource.depends_on]
}


resource "aws_rds_cluster_instance" "replicas" {
  for_each = var.cluster_enabled ? var.instances : {}

  identifier = "${local.cluster_identifier}-${replace(each.key, "_", "-")}"

  cluster_identifier = local.cluster_identifier

  db_subnet_group_name = aws_db_subnet_group.this[0].id
  instance_class       = each.value["instance_class"]

  engine                     = var.aurora_engine
  engine_version             = var.mysql_version
  auto_minor_version_upgrade = var.auto_minor_version_upgrade

  lifecycle {
    ignore_changes = [engine_version]
  }

  promotion_tier = lookup(each.value, "promotion_tier", 0)

  apply_immediately = var.apply_immediately

  ca_cert_identifier = var.ca_cert_identifier

  monitoring_role_arn          = var.monitoring_role_arn
  monitoring_interval          = var.metric_collection_interval
  performance_insights_enabled = var.performance_insights_enabled

  tags = var.tags
}


resource "aws_rds_cluster_endpoint" "custom_endpoint" {
  for_each = var.cluster_enabled ? local.endpoints : []

  cluster_identifier          = local.cluster_identifier
  cluster_endpoint_identifier = "${local.cluster_identifier}-${replace(each.key, "_", "-")}"
  custom_endpoint_type        = "READER"

  static_members = local.endpointsmap[each.key]

  tags = var.tags

}

resource "null_resource" "depends_on" {
  count = var.cluster_enabled ? 1 : 0

  triggers = {
    # The reference to the variable here creates an implicit
    # dependency on the variable.
    dependency = element(concat(var.depends_on_instances, [""]), 0)
  }
}


