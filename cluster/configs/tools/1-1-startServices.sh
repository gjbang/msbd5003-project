#!/bin/bash

configPath="/opt/module"
serverName=`hostname`
HIVE_LOG_DIR=$configPath/hive/logs

# print format log information
log_info(){
    echo -e "`date +%m-%d-%H:%M:%S`:\033[34m [info] \033[m $1"
}

log_debug(){
    echo -e "`date +%m-%d-%H:%M:%S`:\033[32m [debug] \033[m $1"
}

log_warn(){
    echo -e "`date +%m-%d-%H:%M:%S`:\033[33m [warning] \033[m $1" 
}

log_error(){
    echo -e "`date +%m-%d-%H:%M:%S`:\033[31m [error] \033[m $1"
}


check_process(){
    pid=$(ps -ef 2>/dev/null | grep -v grep | grep -i $1 | awk '{print $2}')
    ppid=$(netstat -nltp 2>/dev/null | grep $2 | awk '{print $7}' | cut -d '/' -f 1)
    echo $pid
    [[ "$pid" =~ "$ppid" ]] && [ "$ppid" ] && return 0 || return 1
}


# run ssh serivce
log_info "start ssh service"
service ssh start


log_info "start master service"

# start hadoop
log_info "start hadoop service"
$configPath/hadoop/sbin/start-dfs.sh
$configPath/hadoop/sbin/start-yarn.sh
$configPath/hadoop/bin/mapred --daemon start historyserver

# start zookeeper
log_info "start zookeeper service"
$configPath/zookeeper/bin/zkServer.sh start

# start kafka
log_info "start kafka service"
$configPath/kafka/bin/kafka-server-start.sh -daemon $configPath/kafka/config/server.properties

# /opt/module/kafka/bin/kafka-server-start.sh -daemon /opt/module/kafka/config/server.properties

# create kafka topic
log_info "create kafka topic"
if [ $serverName == "worker02" ]; then
    log_info "create kafka topic"
    $configPath/kafka/bin/kafka-topics.sh  --create --bootstrap-server `hostname`:9092 --replication-factor 1 --partitions 1 --topic gh_activity
fi

# /opt/module/kafka/bin/kafka-topics.sh  --list --bootstrap-server `hostname`:9092
# /opt/module/kafka/bin/kafka-topics.sh  --create --bootstrap-server `hostname`:9092 --replication-factor 1 --partitions 1 --topic gh_activity
# /opt/module/kafka/bin/kafka-topics.sh  --create --bootstrap-server localhost:9092 --replication-factor 1 --partitions 1 --topic gh_activity
# start flume
log_info "start flume service"

if [ $serverName == "worker02" ]; then
    log_info "start flume service"
    # start master01 node
    nohup $configPath/flume/bin/flume-ng agent -n a1 -c $configPath/flume/conf -f $configPath/flume/conf/file_to_kafka.conf -Dflume.root.logger=INFO,console &
    nohup $configPath/flume/bin/flume-ng agent -n a2 -c $configPath/flume/conf -f $configPath/flume/conf/kafka_to_hdfs_log.conf -Dflume.root.logger=INFO,console &
fi

# # flume inspect /opt/data/*.json changes, and send to kafka
# nohup $configPath/flume/bin/flume-ng agent -n a1 -c $configPath/flume/conf -f $configPath/flume/conf/file_to_kafka.conf -Dflume.root.logger=INFO,console &
# nohup /opt/module/flume/bin/flume-ng agent -n a1 -c /opt/module/flume/conf -f /opt/module/flume/conf/file_to_kafka.conf -Dflume.root.logger=INFO,console &
# # kafka inspect kafka topic, and send to hdfs
# nohup $configPath/flume/bin/flume-ng agent -n a2 -c $configPath/flume/conf -f $configPath/flume/conf/kafka_to_hdfs_log.conf -Dflume.root.logger=INFO,console &
# nohup /opt/module/flume/bin/flume-ng agent -n a2 -c /opt/module/flume/conf -f /opt/module/flume/conf/kafka_to_hdfs_log.conf -Dflume.root.logger=INFO,console &
# bin/flume-ng agent -c conf/ -n a1 -f conf/file_to_kafka.conf -Dflume.root.logger=INFO,console

# start hbase
log_info "start hbase service"
$configPath/hbase/bin/start-hbase.sh


# start hive
log_info "start hive service"
# start_hive(){
#     metapid=$(check_process HiveMetastore 9083)
#     cmd="nohup hive --service metastore >$HIVE_LOG_DIR/metastore.log 2>&1 &"
#     [ -z "$metapid" ] && eval $cmd || log_info "Metastroe服务已启动"
#     server2pid=$(check_process HiveServer2 10000)
#     cmd="nohup hive --service hiveserver2 >$HIVE_LOG_DIR/hiveServer2.log 2>&1 &"
#     [ -z "$server2pid" ] && eval $cmd || log_info "HiveServer2服务已启动"
# }
# start_hive
nohup $configPath/hive/bin/hive --service metastore > $HIVE_LOG_DIR/metastore-m.log 2>&1 &
nohup $configPath/hive/bin/hive --service hiveserver2 > $HIVE_LOG_DIR/hiveServer2-m.log 2>&1 &


# $configPath/hive/bin/hive --service metastore &
# $configPath/hive/bin/hive --service hiveserver2 &

# start spark
log_info "start spark service"
if [ $serverName == "master01" ]; then
    log_info "start spark service"

    # start master01 node
    $configPath/spark/sbin/start-master.sh
    # start master01 node as a slave
    $configPath/spark/sbin/start-worker.sh spark://master01:7077

    # create history log directory
    $configPath/hadoop/bin/hdfs dfs -test -e /user/hadoop/evtlogs
    if [ $? -ne 0 ]; then
        log_warn "hdfs event path doesn't exist"
        $configPath/hadoop/bin/hdfs dfs -mkdir -p /user/hadoop/evtlogs
    fi

    # start spark history server -- 18080
    $configPath/spark/sbin/start-history-server.sh
else
    log_info "start spark service"
    $configPath/spark/sbin/start-worker.sh spark://master01:7077
fi


# start mysql for worker02
if [ $serverName == "worker02" ]; then
    log_info "start mysql service"
    service mysql restart
fi


# start flink services
if [ $serverName == "master01" ]; then
    log_info "start flink service"
    $configPath/flink/bin/start-cluster.sh
fi