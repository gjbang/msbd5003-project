#!/bin/bash

# Global and static variables

configPath="/opt/module"
sparkVersion="3.3.2"
hadoopVersion="3.3.2"
graphFrameVersion="graphframes-0.8.2-spark3.0-s_2.12.jar"
zookeeperVersion="3.7.1"
scalaVersion="2.12"
kafkaVersion="3.4.0"
flumeVersion="1.11.0"
hiveVersion="3.1.2"
mysqlVersion="0.8.24-1"
jdbcVersion="8.0.32-1"
hbaseVersion="2.5.3"
flinkVersion="1.17.0"
serverName=`hostname`
initPassWd="heikediguo"

# param list to execute different config function
declare -A paramDict
paramDict=(
    ['system']="system_config"
    ['spark']="spark_config"
    ['hadoop']="hadoop_config"
    ['zookeeper']="zookeeper_config"
    ['scala']="scala_config"
    ['kafka']="kafka_config"
    ['flume']="flume_config"
    ['hive']="hive_config"
    ['ssh']="ssh_config"
    ['mysql']="mysql_config"
    ['hbase']="hbase_config"
    ['flink']="flink_config"
)
paramList=(
    "system"
    "spark"
    "hadoop"
    "zookeeper"
    "scala"
    "kafka"
    "flume"
    "mysql"
    "hbase"
    "hive"
    "flink"
    )
# record all nodes name for initialize slaves, workers, etc.
nodeList=()

# Environment variables needed to add to bashrc
declare -A Environments
Environments=(
    ['PYSPARK_PYTHON']="export PYSPARK_PYTHON=python3"
    ['SPARK_HOME']="export SPARK_HOME=\"$configPath/spark\""
    ['SPARK_OPTS']="export SPARK_OPTS=\"--packages graphframes:graphframes:0.8.2-spark3.0-s_2.12\""
    ['SPARK_LOCAL_IP']="export SPARK_LOCAL_IP=\"127.0.0.1\""
    # ['$PYSPARK_DRIVER_PYTHON"']="export PYSPARK_DRIVER_PYTHON=\"jupyter\""
    # ['$PYSPARK_DRIVER_PYTHON_OPTS']="export PYSPARK_DRIVER_PYTHON_OPTS=\"notebook\""
    ['HADOOP_HOME']="export HADOOP_HOME=\"$configPath/hadoop\""
    ['HADOOP_CONF_DIR']="export HADOOP_CONF_DIR=\"$configPath/hadoop/etc/hadoop\""
    ['HADOOP_LOG_DIR']="export HADOOP_LOG_DIR=\"/var/log/hadoop\""
    ['KAFKA_HOME']="export KAFKA_HOME=\"$configPath/kafka\""
    ['HIVE_HOME']="export HIVE_HOME=\"$configPath/hive\""
    ['JAVA_HOME']="export JAVA_HOME=\"/usr/lib/jvm/java-8-openjdk-amd64\""
    ['HBASE_HOME']="export HBASE_HOME=\"$configPath/hbase\""
    ['PATH']="export PATH=\$PATH:\$SPARK_HOME/bin:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin:\$KAFKA_HOME/bin:\$HIVE_HOME/bin:\$HBASE_HOME/bin"
)

# generate different kafka block id config file for each node
declare -A kafkaBlockId
kafkaBlockId=(
    ['master01']="broker.id=1"
    ['master02']="broker.id=2"
    ['worker01']="broker.id=3"
    ['worker02']="broker.id=4"
    ['worker03']="broker.id=5"
    ['worker04']="broker.id=6"
)


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


# ====== Basic System Config ======
system_config(){
    log_info "Start to update system configuration"
    log_info "apt update and install software"
    # java
    sudo add-apt-repository -y ppa:openjdk-r/ppa
    sudo apt-get -y update >/dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install openjdk-8-jdk >/dev/null 2>&1
    sudo update-java-alternatives --set java-1.8.0-openjdk-amd64  >/dev/null 2>&1

    sleep 1

    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install openjdk-8-jdk >/dev/null 2>&1
    sudo update-java-alternatives --set java-1.8.0-openjdk-amd64

    # install corresponding pip
    sudo apt -y install python3-pip >/dev/null 2>&1

    log_info "pip install basic python package"
    pip3 install numpy matplotlib jupyterlab pyspark==3.3.2 >/dev/null 2>&1
    pip3 install -r $HOME/configs/system/requirement.txt >/dev/null 2>&1

    # log_info "add host mapping"
    cat $HOME/configs/system/hosts >> /etc/hosts
    # backup hostname and ip for nodes' hot-updating to file host.old
    cp $HOME/configs/system/hosts $HOME/configs/system/hosts.old

    # == create config file path
    log_info "create config path"
    if [ ! -d "$configPath" ]; then
        log_warn "$configPath not exists, create"
        cd /opt
        mkdir module
    fi

    if [ ! -d "/opt/data" ]; then
        log_warn "/opt/data not exists, create"
        cd /opt
        mkdir data
        cd /opt/data
        mkdir flume
    fi

    # == set path environment vars
    log_info "set path environment vars"
    for key in ${!Environments[@]}; do
        if [ -z "${!key}" ]; then
            echo -e "${Environments[$key]}" >> ~/.bashrc
            log_info "${key} has been set"
        else
            # skip "PATH"
            if [ "${key}" == "PATH" ]; then
                echo -e "${Environments[$key]}" >> ~/.bashrc
            else
                log_warn "${key} has existed: ${!key}"
            fi
        fi
    done

    # == source bashrc
    source ~/.bashrc
}


# ====== Config Spark Basic Lib ======
spark_config(){

    cd $configPath
    log_warn "current working path: `pwd`"

    log_info "install spark"

    # == download spark
    if [ ! -f "spark-$sparkVersion-bin-hadoop3.tgz" ]; then
        log_info "download spark, version: $sparkVersion"
        wget https://mirrors.aliyun.com/apache/spark/spark-$sparkVersion/spark-$sparkVersion-bin-hadoop3.tgz -P ./  -r -c -O "spark-$sparkVersion-bin-hadoop3.tgz"
        # wget https://mirrors.aliyun.com/apache/spark/spark-3.3.2/spark-3.3.2-bin-hadoop3.tgz -P ./  -r -c -O "spark-3.3.2-bin-hadoop3.tgz"
        # https://mirrors.aliyun.com/apache/spark/spark-3.3.2/spark-3.3.2-bin-hadoop3.tgz?spm=a2c6h.25603864.0.0.405e74a8BisO0N
    else
        log_warn "Spark $sparkVersion has existed!"
    fi

    tar -zxvf spark-$sparkVersion-bin-hadoop3.tgz >/dev/null 2>&1 
    mv spark-$sparkVersion-bin-hadoop3 spark

    # == download graphframe
    if [ ! -f "$graphFrameVersion" ]; then
        log_info "download GraphFrame"
        wget --content-disposition https://repos.spark-packages.org/graphframes/graphframes/0.8.2-spark3.0-s_2.12/graphframes-0.8.2-spark3.0-s_2.12.jar -P ./  -r -c -O "graphframes-0.8.2-spark3.0-s_2.12.jar"
        # install graphframe
        cp graphframes-0.8.2-spark3.0-s_2.12.jar $configPath/spark/jars/
    else
        log_warn "GraphFrame has existed!"
    fi

    # == config spark env vars == #
    cp $HOME/configs/spark/* $configPath/spark/conf/
    # if not config local ip, web ui may mapping to localhost:xxxx
    # which cannot be visited by outer network
    # not need to modify /etc/hosts
    # corresponding: netstat -ap | grep java; ps -ef | grep spark
    echo -e "export SPARK_LOCAL_IP=$serverName\n" >> $configPath/spark/conf/spark-env.sh
    log_info "Spark config finished"
}


# ====== Config Hadoop Basic Lib ======
hadoop_config(){

    cd $configPath
    log_warn "current working path: `pwd`"

    log_info "Start to config hadoop"
    # == download hadoop
    if [ ! -f "hadoop-$hadoopVersion.tar.gz" ]; then
        log_info "download hadoop, version: $hadoopVersion"
        # wget https://archive.apache.org/dist/hadoop/common/hadoop-$hadoopVersion/hadoop-$hadoopVersion.tar.gz -P ./  -r -c -O "hadoop-$hadoopVersion.tar.gz"
        wget https://mirrors.aliyun.com/apache/hadoop/common/hadoop-$hadoopVersion/hadoop-$hadoopVersion.tar.gz -P ./  -r -c -O "hadoop-$hadoopVersion.tar.gz"
    else
        log_warn "Hadoop $hadoopVersion has existed!"
    fi

    # == untar hadoop
    tar -zxvf hadoop-$hadoopVersion.tar.gz >/dev/null 2>&1
    mv hadoop-$hadoopVersion hadoop

    # == move configure file to hadoop config path
    log_info "move configure file to hadoop config path"
    hadoopConfigDir="$configPath/hadoop/etc/hadoop/"
    cp $HOME/configs/hadoop/* $hadoopConfigDir

    # == set privilege of hadoop
    log_info "set privilege of hadoop"
    chmod a+x $configPath/hadoop/sbin/start-dfs.sh
    chmod a+x $configPath/hadoop/sbin/start-yarn.sh

    # == create HDFS namenode and datanode directory
    log_info "create HDFS namenode and datanode directory"
    mkdir -p $configPath/hdfs/namenode
    mkdir -p $configPath/hdfs/datanode

    # == format namenode
    log_info "format namenode"
    $configPath/hadoop/bin/hdfs namenode -format

    log_info "Hadoop config finished"
}



# ====== zookeeper config ======
zookeeper_config(){
    
    cd $configPath    
    log_warn "current working path: `pwd`"

    # ====== delete old zookeeper ======
    if [ -d "zookeeper" ]; then
        log_info "delete old zookeeper"
        rm -rf zookeeper
    fi

    if [ ! -f "zookeeper-$zookeeperVersion-bin.tar.gz" ]; then
        # download
        log_info "download zookeeper, version: $zookeeperVersion"
        wget https://mirrors.aliyun.com/apache/zookeeper/zookeeper-$zookeeperVersion/apache-zookeeper-$zookeeperVersion-bin.tar.gz -P ./  -r -c -O "zookeeper-$zookeeperVersion-bin.tar.gz"
    else
        log_warn "Zookeeper $zookeeperVersion has existed!"
    fi

    # decompress
    tar -zxvf zookeeper-$zookeeperVersion-bin.tar.gz >/dev/null 2>&1
    # rename
    mv apache-zookeeper-$zookeeperVersion-bin zookeeper

    # ======= configs =======
    # modify myid according to serverName and nodeList
    index=2
    cid=2
    for node in ${nodeList[@]}
    do
        if [ $node == $serverName ]; then
            cid=$index
        fi
        echo -e "server.$index=$node:2888:3888" >> $HOME/configs/zookeeper/zoo.cfg
        index=`expr $index + 1`
    done
    echo $cid > $HOME/configs/zookeeper/myid

    # print zookeeper config and myid
    log_info "zookeeper config: "
    tail -n 5 $HOME/configs/zookeeper/zoo.cfg
    log_info "zookeeper myid: "
    cat $HOME/configs/zookeeper/myid
    
    mkdir /opt/module/zookeeper/zkData
    cp $HOME/configs/zookeeper/zoo.cfg $configPath/zookeeper/conf/zoo.cfg
    cp $HOME/configs/zookeeper/myid $configPath/zookeeper/zkData/myid

}


# ====== kafka config ======
kafka_config(){
    cd $configPath
    log_warn "current working path: `pwd`"

    # ===== delete old kafka =====
    if [ -d "$configPath/kafka" ]; then
        log_warn "delete old kafka"
        rm -rf $configPath/kafka
    fi

    if [ ! -f "kafka_$scalaVersion-$kafkaVersion.tgz" ]; then
        # download
        log_info "download kafka, version: $kafkaVersion"
        wget https://mirrors.aliyun.com/apache/kafka/$kafkaVersion/kafka_$scalaVersion-$kafkaVersion.tgz -P ./  -r -c -O "kafka_$scalaVersion-$kafkaVersion.tgz"
    else
        log_warn "Kafka $kafkaVersion has existed!"
    fi

    # decompress
    tar -zxvf kafka_$scalaVersion-$kafkaVersion.tgz >/dev/null 2>&1
    # rename
    mv kafka_$scalaVersion-$kafkaVersion kafka

    #config
    mkdir $configPath/kafka/datas

    # ! change broker.id ---- vim /opt/module/kafka/config/server.properties
    find $HOME/configs/kafka/ -name "server.properties" | xargs perl -pi -e "s|broker.id=0|${kafkaBlockId[$serverName]}|g"
    # change listeners in /opt/module/kafka/config/server.properties
    sed -i "s|listeners=PLAINTEXT://master01:9092|listeners=PLAINTEXT://$serverName:9092|g" $HOME/configs/kafka/server.properties
    # change channel bootstrap.servers in kafka_to_hdfs_log.conf
    sed -i "s|bootstrap.servers = master01:9092|bootstrap.servers = $serverName:9092|g" $HOME/configs/kafka/kafka_to_hdfs_log.conf

    cp $HOME/configs/kafka/server.properties $configPath/kafka/config/server.properties

}


# ====== flume config ======
flume_config(){
    cd $configPath
    log_warn "current working path: `pwd`"

    # ===== delete old flume =====
    if [ -d "flume" ]; then
        log_info "delete old flume"
        rm -rf flume
    fi

    if [ ! -f "apache-flume-$flumeVersion-bin.tar.gz" ]; then
        # download
        log_info "download flume, version: $flumeVersion"
        wget https://mirrors.aliyun.com/apache/flume/$flumeVersion/apache-flume-$flumeVersion-bin.tar.gz -P ./  -r -c -O "apache-flume-$flumeVersion-bin.tar.gz"
    else
        log_warn "Flume $flumeVersion has existed!"
    fi

    # decompress
    tar -zxvf apache-flume-$flumeVersion-bin.tar.gz >/dev/null 2>&1
    # rename
    mv apache-flume-$flumeVersion-bin flume
    # create config directory
    mkdir $configPath/flume/conf

    # remove useless jar lib
    rm -f $configPath/flume/lib/guava-11.0.2.jar
    # copy guava-27.0-jre.jar to flume or will cause java-exception-event bus error
    cp $configPath/hadoop/share/hadoop/common/lib/guava-27.0-jre.jar $configPath/flume/lib/
    mv $configPath/flume/lib/guava-27.0-jre.jar $configPath/flume/lib/guava-27.0.jar
    # to avoid "Exception in thread "main" java.lang.NoClassDefFoundError: org/apache/hadoop/io/SequenceFile$CompressionType"
    cp $configPath/hadoop/share/hadoop/common/hadoop-common-3.3.2.jar $configPath/flume/lib/
    
    cp $HOME/configs/flume/flume-env.sh $configPath/flume/conf/flume-env.sh

    # change file_to_kafka.conf channel's bootstrap.servers
    sed -i "s|bootstrap.servers = master01:9092|bootstrap.servers = $serverName:9092|g" $HOME/configs/flume/file_to_kafka.conf

    # copy config
    cp $HOME/configs/flume/*.conf $configPath/flume/conf/
    cp $HOME/configs/kafka/*.conf $configPath/flume/conf/

    # copy necessary lib
    cp $configPath/hadoop/share/hadoop/yarn/timelineservice/lib/htrace-core-3.1.0-incubating.jar $configPath/flume/lib/
    rm -f $configPath/flume/lib/commons-io-2.11.0.jar
    cp $configPath/hadoop/share/hadoop/common/lib/commons-io-2.8.0.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/common/lib/commons-configuration2-2.1.1.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/common/lib/hadoop-auth-3.3.2.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/hdfs/hadoop-hdfs-3.3.2.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/common/lib/woodstox-core-5.3.0.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/common/lib/stax2-api-4.2.1.jar $configPath/flume/lib/
    cp $configPath/hadoop/share/hadoop/hdfs/hadoop-hdfs-client-3.3.2.jar $configPath/flume/lib/
}




mysql_config(){
    # == create config file path
    # == create config file path
    log_info "create config path"
    if [ ! -d "$configPath" ]; then
        log_warn "$configPath not exists, create"
        cd /opt
        mkdir module
    fi

    if [ ! -d "/opt/data" ]; then
        log_warn "/opt/data not exists, create"
        cd /opt
        mkdir data
        cd /opt/data
        mkdir flume
    fi


    cd $configPath
    log_warn "current working path: `pwd`"

    # ===== delete old mysql =====
    if type "mysql" > /dev/null; then
        log_info "delete old mysql"
        sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge "mysql*" -y 
        sudo DEBIAN_FRONTEND=noninteractive rm -rf /etc/mysql/ /var/lib/mysql
    fi

    # ===== download mysql =====
    if ! type "mysql" > /dev/null; then
        # download
        log_info "download mysql, version: $mysqlVersion"
        wget "https://dev.mysql.com/get/mysql-apt-config_${mysqlVersion}_all.deb" -P ./  -r -c -O "mysql-apt-config_${mysqlVersion}_all.deb"
        sudo DEBIAN_FRONTEND=noninteractive apt install $configPath/mysql-apt-config_${mysqlVersion}_all.deb

        # install mysql from apt repo
        sudo apt update
        sudo DEBIAN_FRONTEND=noninteractive apt-get -yq install mysql-server
        sudo DEBIAN_FRONTEND=noninteractive apt-get -yq install mysql-client

        # ====== configs user passwd and privileges =======
        mysql -uroot < $HOME/configs/mysql/config.sql

        # ====== change mysql config -- bind ip address -- open mysql to all address =======
        # replace /etc/mysql/mysql.conf.d/mysqld.cnf bind-address = 127.0.0.1 by bind-address = 0.0.0.0
        sudo sed -i "s/bind-address.*/bind-address = 0.0.0.0/g" /etc/mysql/mysql.conf.d/mysqld.cnf
        sudo killall -u mysql
        
        # ====== start mysql =======
        sudo service mysql restart
        # open mysql when system start automatically
        sudo update-rc.d -f mysql defaults

        # open port
        sudo ufw allow 3306

        sudo netstat -tulnp | grep LISTEN | grep mysql

    else
        log_warn "Mysql $mysqlVersion has existed!" 
    fi

    log_info "mysql config finished"

}


# TODO: change hite-site.xml adapt to slaves
hbase_config(){
    cd $configPath
    log_warn "current working path: `pwd`"

    # ===== delete old hbase =====
    if [ -d "hbase" ]; then
        log_info "delete old hbase"
        rm -rf hbase
    fi

    # ===== download hbase =====
    if [ ! -f "hbase-$hbaseVersion-bin.tar.gz" ]; then
        # download
        log_info "download hbase, version: $hbaseVersion"
        wget https://mirrors.aliyun.com/apache/hbase/$hbaseVersion/hbase-$hbaseVersion-bin.tar.gz -P ./  -r -c -O "hbase-$hbaseVersion-bin.tar.gz"
    else
        log_warn "Hbase $hbaseVersion has existed!"
    fi

    # decompress
    tar -zxvf hbase-$hbaseVersion-bin.tar.gz >/dev/null 2>&1
    # rename
    mv hbase-$hbaseVersion hbase

    cp $HOME/configs/hbase/* $configPath/hbase/conf/

    # produce all node list string
    nodesStr=""
    for node in ${!nodeList[@]}; do
        nodesStr="$nodesStr,$node"
    done
    # remove first ',' 
    keyReplace="hbase.zookeeper.quorum"
    sed -i "/>$keyReplace</{n;s#.*#        <value>$nodeStr</value>#}" $configPath/hbase/conf/hbase-site.xml

    log_info "hbase config done"
    
}


# ====== hive config ======
# 1. download hive and decompress
# 2. adjust outer lib (JDBC, etc)
# 3. init with MySQL
hive_config(){
    cd $configPath
    log_warn "current working path: `pwd`"

    # ===== delete old hive =====
    if [ -d "hive" ]; then
        log_info "delete old hive"
        rm -rf hive
    fi

    # ===== download hive =====
    if [ ! -f "apache-hive-$hiveVersion-bin.tar.gz" ]; then
        # download
        log_info "download hive, version: $hiveVersion"
        wget https://mirrors.aliyun.com/apache/hive/hive-$hiveVersion/apache-hive-$hiveVersion-bin.tar.gz -P ./  -r -c -O "apache-hive-$hiveVersion-bin.tar.gz"
    else
        log_warn "Hive $hiveVersion has existed!"
    fi

    # decompress
    tar -zxvf apache-hive-$hiveVersion-bin.tar.gz >/dev/null 2>&1
    # rename and logs path
    mv apache-hive-$hiveVersion-bin hive
    mkdir $configPath/hive/logs/

    # === config outer lib for hive ===

    # delete old guava-19.0.jar
    rm -f $configPath/hive/lib/guava-19.0.jar 
    # copy guava-19.0.jar from hadoop share
    cp $configPath/hadoop/share/hadoop/common/lib/guava-27.0-jre.jar $configPath/hive/lib/

    # download mysql jdbc
    wget "https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j_8.0.32-1ubuntu22.04_all.deb" -P ./  -r -c -O "mysql-jdbc.deb"
    DEBIAN_FRONTEND=noninteractive apt install ./mysql-jdbc.deb
    cp /usr/share/java/mysql-connector-j-8.0.32.jar $configPath/hive/lib/
    cp /usr/share/java/mysql-connector-j-8.0.32.jar $configPath/spark/jars/

    # === move config files ===
    cp $HOME/configs/hive/* $configPath/hive/conf/

    # init hive metadata,
    ## ! This need set $HADOOP_HOME, so need source, there cannot be executed
    if [ $serverName = "worker02" ]; then
        log_info "init hive metadata"
        $configPath/hive/bin/schematool -dbType mysql -initSchema -verbose
    fi

    # === config json serde ===
    cd $configPath/hive
    mkdir auxlib
    cp $HOME/configs/hive/json-serde-1.3.8-jar-with-dependencies.jar $configPath/hive/auxlib/
    cp $HOME/configs/hive/json-serde-1.3.8-jar-with-dependencies.jar $configPath/hive/lib/

    # config spark on hive
    cp $HOME/configs/hive/hive-site.xml $configPath/spark/conf/
    cp $HOME/configs/hive/json-serde-1.3.8-jar-with-dependencies.jar $configPath/spark/jars/

    log_info "hive config done"
}


# help to config ssh, main function:
# 1. generate ssh key
# 2. config local ssh authorized_keys
# 3. config sshd_config: all key/password login, 
# 4. create root password
ssh_config(){
    # generate ssh key
    log_info "ssh config"
    ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    # config ssh
    echo -e "Port 22\nPubkeyAuthentication yes\n" >> /etc/ssh/sshd_config 
    find /etc/ssh/ -name sshd_config | xargs perl -pi -e "s|PermitRootLogin no|PermitRootLogin yes|g"
    # open password login, for ssh-copy id
    find /etc/ssh/ -name sshd_config | xargs perl -pi -e "s|PasswordAuthentication no|PasswordAuthentication yes|g"
    # not input yes when ssh-copy-id
    sed -i '/StrictHostKeyChecking/c StrictHostKeyChecking no' /etc/ssh/ssh_config

    # set a password for root, for ssh-copy-id
    echo -e "root:$initPassWd" | chpasswd

    # update config
    service ssh restart
}



flink_config(){
    cd $configPath
    log_warn "current working path: `pwd`"

    log_info "install flink"

    # == download flink
    if [ ! -f "flink-$flinkVersion-bin.tgz" ]; then
        log_info "download flink, version: $flinkVersion"
        wget https://mirrors.aliyun.com/apache/flink/flink-$flinkVersion/flink-$flinkVersion-bin-scala_$scalaVersion.tgz -P ./  -r -c -O "flink-$flinkVersion-bin.tgz"
        # wget https://mirrors.aliyun.com/apache/flink/flink-$flinkVersion/python/apache_flink-$flinkVersion-cp310-cp310-manylinux1_x86_64.whl  -P ./  -r -c -O "apache_flink-$flinkVersion-cp310-cp310-manylinux1_x86_64.whl"
    else
        log_warn "flink $flinkVersion has existed!"
    fi

    tar -zxvf flink-$flinkVersion-bin.tgz >/dev/null 2>&1 
    mv flink-$flinkVersion flink

    # pip3 install $configPath/apache_flink-$flinkVersion-cp310-cp310-manylinux1_x86_64.whl

    # == config spark env vars == #
    cp $HOME/configs/flink/* $configPath/flink/conf/

    log_info "flink config finished"
}


# directly get the node list from hosts, not need to config manually
generate_node_list(){
    # generate worker list
    log_info "generate worker list"

    # read lines from hosts and split by space
    while read line
    do
        # split by space
        arr=($line)
        # get server name
        nodeName=${arr[1]}

        # add node name 
        # if [ $serverName != "master01" ]; then
        nodeList[${#nodeList[@]}]=$nodeName
        # fi

        log_info "inspect node name: $nodeName"
    done < $HOME/configs/system/hosts

    # write node list to slaves, workers, etc
    cat /dev/null > $HOME/configs/spark/slaves
    cat /dev/null > $HOME/configs/hadoop/workers
    cat /dev/null > $HOME/configs/hbase/regionservers
    cat /dev/null > $HOME/configs/hbase/backup-masters
    cat /dev/null > $HOME/configs/flink/workers
    for node in ${nodeList[@]}; do
        echo $node >> $HOME/configs/spark/slaves
        echo $node >> $HOME/configs/hadoop/workers
        echo $node >> $HOME/configs/hbase/regionservers
        if [ $node != "master01" ]; then
            echo $node >> $HOME/configs/hbase/backup-masters
        fi
        echo $node >> $HOME/configs/flink/workers
    done


}

# ====== main execution process ======
# check if execute all configs
paramNum=$#
if [ $paramNum -eq 0 ]; then
    log_info "No args, use default config, execute all config"
fi

# == generate node name from hosts file ==
generate_node_list

# == execute config for different args
for param in ${paramList[@]}
do
    if echo $@ | grep -o "\b$param\b"; then
        log_info "execute config for $param"
        ${paramDict[$param]}
    elif [ $paramNum -eq 0 ]; then
        log_info "execute config for $param"
        # only master01 can install mysql
        if [ $param == "mysql" ]; then
            log_warn "skip mysql config for $serverName"
            continue
        fi
        ${paramDict[$param]}
    else
        log_warn "No config for $param"
    fi
done

log_info "====== config done ======"