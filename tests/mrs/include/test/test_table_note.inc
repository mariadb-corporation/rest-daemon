--disable_result_log
--disable_query_log

CREATE TABLE IF NOT EXISTS `test`.`note` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `user_id` BINARY(16) NOT NULL,
  `title` VARCHAR(255) NOT NULL,
  `create_date` DATETIME NOT NULL DEFAULT now(),
  `last_update` DATETIME NOT NULL DEFAULT now(),
  `pinned` BIT(1) NOT NULL DEFAULT 0,
  `locked_down` BIT(1) NOT NULL DEFAULT 0,
  `shared` BIT(1) NOT NULL DEFAULT 0 COMMENT 'The shared column is automatically updated by AFTER INSERT / DELETE triggers on user_has_note.',
  `content` VARCHAR(2000) NULL,
  `tags` JSON NULL,
  PRIMARY KEY (`id`),
  INDEX `created_by` (`user_id` ASC) VISIBLE,
  INDEX `last_update` (`last_update` ASC) VISIBLE,
  INDEX `create_date` (`create_date` ASC) VISIBLE,
  FULLTEXT INDEX `content_ft` (`content`) VISIBLE)
ENGINE = InnoDB;

use mariadb_rest_service;
START TRANSACTION;
if ($mrs_schema_version == 2)
{
  INSERT INTO `rest_object` (`id`,`rest_schema_id`,`name`,`request_path`,`enabled`,`object_type`,`crud_operations`,`format`,`items_per_page`,`media_type`,`auto_detect_media_type`,`requires_auth`,`auth_stored_procedure`,`row_user_ownership_enforced`,`row_user_ownership_column`,`options`,`details`,`comments`) VALUES (1,@schema_id,'note','/note',1,'TABLE','CREATE,READ,UPDATE,DELETE','FEED',NULL,NULL,0,1,'',1,'user_id',NULL,NULL,'');
  INSERT INTO `data_mapping` (`id`,`rest_object_id`,`name`,`kind`,`position`,`sdk_options`,`comments`) VALUES (2,1,'MyServiceMrsNotesNote','RESULT',0,NULL,NULL);
}

# restd: the ids are UUIDs in 5.0.0 (`00000000-0000-0000-0000-<n>`)
if ($mrs_schema_version > 2)
{
  INSERT INTO `rest_object` (`id`,`rest_schema_id`,`name`,`request_path`,`enabled`,`object_type`,`crud_operations`,`format`,`items_per_page`,`media_type`,`auto_detect_media_type`,`requires_auth`,`auth_stored_procedure`, `options`,`details`,`comments`) VALUES ('00000000-0000-0000-0000-000000000001',@schema_id,'note','/note',1,'TABLE','CREATE,READ,UPDATE,DELETE','FEED',NULL,NULL,0,1,'',NULL,NULL,'');
  INSERT INTO `data_mapping` (`id`,`rest_object_id`,`name`,`kind`,`position`,`sdk_options`,`comments`, `row_ownership_field_id`,`options`) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','MyServiceMrsNotesNote','RESULT',0,NULL,NULL, '00000000-0000-0000-0000-000000000009', '{"dataMappingViewInsert":true, "dataMappingViewUpdate":true, "dataMappingViewDelete":true}');
  INSERT INTO `data_mapping_reference` (`id`, `unnest`, `reference_mapping`, `options`)
    VALUES('00000000-0000-0000-0000-000000001001', 0, '{}', NULL);
#    '{"kind": "n:1", "to_many": false, "constraint": "mrs_notes.fk_note_user1", "column_mapping": [{"ref": "id", "base": "user_id"}], "referenced_table": "user", "referenced_schema": "mrs_notes"}',
#    '{"duality_view_delete": true, "duality_view_insert": true, "duality_view_update": true, "dataMappingViewDelete": true, "dataMappingViewInsert": true, "dataMappingViewUpdate": true}'
#    );
  INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`)
      VALUES ('00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000002',NULL,'00000000-0000-0000-0000-000000001001','user',102,NULL,0,1,0,0,0,NULL,NULL);
}

#INSERT INTO `object_field` #(`id`,`object_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES #(3,2,NULL,?,'userHasNote',1001,NULL,0,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000002',NULL,NULL,'title',3,'{\"name\": \"title\", \"comment\": \"\", \"datatype\": \"varchar(255)\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000002',NULL,NULL,'id',1,'{\"name\": \"id\", \"comment\": \"\", \"datatype\": \"int unsigned\", \"not_null\": true, \"is_unique\": false, \"is_primary\": true, \"is_generated\": false, \"id_generation\": \"auto_inc\"}',1,1,1,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000002',NULL,NULL,'lastUpdate',5,'{\"name\": \"last_update\", \"comment\": \"\", \"datatype\": \"datetime\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000002',NULL,NULL,'pinned',6,'{\"name\": \"pinned\", \"comment\": \"\", \"datatype\": \"bit(1)\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000002',NULL,NULL,'userId',2,'{\"name\": \"user_id\", \"comment\": \"\", \"datatype\": \"binary(16)\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000002',NULL,NULL,'shared',8,'{\"name\": \"shared\", \"comment\": \"The shared column is automatically updated by AFTER INSERT / DELETE triggers on user_has_note.\", \"datatype\": \"bit(1)\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000002',NULL,NULL,'tags',10,'{\"name\": \"tags\", \"comment\": \"\", \"datatype\": \"json\", \"not_null\": false, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000002',NULL,NULL,'createDate',4,'{\"name\": \"create_date\", \"comment\": \"\", \"datatype\": \"datetime\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000013','00000000-0000-0000-0000-000000000002',NULL,NULL,'lockedDown',7,'{\"name\": \"locked_down\", \"comment\": \"\", \"datatype\": \"bit(1)\", \"not_null\": true, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
INSERT INTO `data_mapping_field` (`id`,`data_mapping_id`,`parent_reference_id`,`represents_reference_id`,`name`,`position`,`db_column`,`enabled`,`allow_filtering`,`allow_sorting`,`no_check`,`no_update`,`sdk_options`,`comments`) VALUES ('00000000-0000-0000-0000-000000000014','00000000-0000-0000-0000-000000000002',NULL,NULL,'content',9,'{\"name\": \"content\", \"comment\": \"\", \"datatype\": \"varchar(2000)\", \"not_null\": false, \"is_unique\": false, \"is_primary\": false, \"is_generated\": false, \"id_generation\": null}',1,1,0,0,0,NULL,NULL);
COMMIT;
use test;
--enable_result_log
--enable_query_log
