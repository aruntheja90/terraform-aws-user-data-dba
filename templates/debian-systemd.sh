
##############
# Install deps
##############

apt-get -y install python-pip pv mysql-client

# Install AWS Client
pip install --upgrade awscli

##
## MySQL Client Configuration
##
cat <<"__EOF__" > /root/${name}.my.cnf
[client]
database=${db_name}
user=${db_user}
password=${db_password}
host=${db_host}
__EOF__
chmod 600 /root/${name}.my.cnf

##
## Makefile for MySQL commands
##

curl https://raw.githubusercontent.com/cloudposse/mysql_fix_encoding/5.0/fix_it.sh -o /usr/local/bin/mysql_latin_utf8.sh
chmod +x /usr/local/bin/mysql_latin_utf8.sh

curl https://raw.githubusercontent.com/cloudposse/rds-snapshot-restore/1.0/rds_restore_cluster_from_snapshot.sh -o /usr/local/bin/rds_restore_cluster_from_snapshot.sh
chmod +x /usr/local/bin/rds_restore_cluster_from_snapshot.sh

cat <<"__EOF__" > /usr/local/include/Makefile.${name}.mysql
DUMP ?= /tmp/mysqldump.sql

.PHONY : ${name}\:db-import
DB ?= ${db_name}
USE_BINARY ?= ${fix_encoding_use_binary}
ENCODING ?= ${encoding}

## Import dump
${name}\:db-import:
	$(eval MY_CNF?=/root/${name}.my.cnf)
	@pv $(DUMP) | sudo mysql --defaults-file=$(MY_CNF)
	MY_CNF=$(MY_CNF) USE_BINARY=$(USE_BINARY) ENCODING=$(ENCODING) DB=$(DB) /usr/local/bin/mysql_latin_utf8.sh | pv | sudo mysql --defaults-file=$(MY_CNF) $(DB)

## DB connect
${name}\:db-connect:
	$(eval MY_CNF?=/root/${name}.my.cnf)
	@sudo mysql --defaults-file=$(MY_CNF) $(DB)

__EOF__
chmod 644 /usr/local/include/Makefile.${name}.mysql

cat <<"__EOF__" > /usr/local/include/Makefile.${name}.aws_mysql
DUMP_BASENAME ?= mysqldump
TIMESTAMP:=$(shell date | md5sum | cut -d" " -f1)
TMP_DIR ?= /tmp/$(TIMESTAMP)
DB ?= ${db_name}
USE_BINARY ?= ${fix_encoding_use_binary}
ENCODING ?= ${encoding}

## Import dump from ${default_dump_source}
${name}\:db-import-from-s3:
	$(eval MY_CNF?=/root/${name}.my.cnf)
	$(eval SOURCE?=${default_dump_source})
	@echo "Create tmp dir..."
	mkdir -p $(TMP_DIR)
	@echo "Fetch dump..."
	aws s3 cp --recursive s3://$(SOURCE)/ $(TMP_DIR)
	@echo "Import base dump..."
	pv $(TMP_DIR)/$(DUMP_BASENAME).sql.gz | gzip -dc | sudo mysql --defaults-file=$(MY_CNF) $(DB)
	@echo "Create additional databases..."
	find $(TMP_DIR) -name "*.gz" -printf "%f\n" | \
		sed -e 's/\..*$///' | \
		sed -e "s/$(DUMP_BASENAME)//" | \
		xargs -I '{}' sudo mysql --defaults-file=$(MY_CNF) -e "CREATE DATABASE IF NOT EXISTS $(DB){}"
	@echo "Import additional dumps..."
	find $(TMP_DIR) -name "*.gz" -printf "%f\n" | \
		sed -e 's/\..*$///' | \
		sed -e "s/$(DUMP_BASENAME)//" | \
		xargs -I '{}' sh -c "pv $(TMP_DIR)/$(DUMP_BASENAME){}.sql.gz | gzip -dc | sudo mysql --defaults-file=$(MY_CNF) $(DB){}"
	@echo "Fix encoding"
	MY_CNF=$(MY_CNF) USE_BINARY=$(USE_BINARY) ENCODING=$(ENCODING) DB=$(DB) /usr/local/bin/mysql_latin_utf8.sh | pv | sudo mysql --defaults-file=$(MY_CNF) $(DB)
	find $(TMP_DIR) -name "*.gz" -printf "%f\n" | \
		sed -e 's/\..*$///' | \
		sed -e "s/$(DUMP_BASENAME)//" | \
		xargs -I '{}' sh -c "MY_CNF=$(MY_CNF) USE_BINARY=$(USE_BINARY) ENCODING=$(ENCODING) DB=$(DB){} /usr/local/bin/mysql_latin_utf8.sh | pv | sudo mysql --defaults-file=$(MY_CNF) $(DB){}"
	@echo "Remove tmp dumps..."
	rm -rf $(TMP_DIR)
__EOF__
chmod 644 /usr/local/include/Makefile.${name}.aws_mysql

cat <<"__EOF__" > /usr/local/include/Makefile.${name}.rds
CLUSTER ?= ${db_cluster_name}

## Restore dump from snapshot. Specify SNAPSHOT_ID and DRY_RUN=false
${name}\:db-restore-from-snapshot:
	$(call assert-set,SNAPSHOT_ID)
	$(call assert-set,DRY_RUN)
	@DRY_RUN=$(DRY_RUN) MASTER_PASSWORD=$(shell sudo cat /root/${name}.my.cnf | grep password | cut -d'=' -f2) /usr/local/bin/rds_restore_cluster_from_snapshot.sh $(CLUSTER) $(SNAPSHOT_ID)

__EOF__
chmod 644 /usr/local/include/Makefile.${name}.rds


