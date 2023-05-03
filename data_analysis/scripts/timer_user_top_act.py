from pyspark.sql import functions as F
from pyspark.sql.types import StringType, StructType, StructField, IntegerType, TimestampType
from pyspark.sql import HiveContext,SparkSession

from datetime import datetime, timedelta
import pandas as pd

import logging
from log import Logger

logger = Logger("/root/test-issue.log", logging.DEBUG, __name__).getlog()

mongodb_name = "results"
table_name = ["eventAllCount","eventAllRatio","eventCount","eventRatio","reposCount","usersCount"]
event_table_name = ["create","delete","issues","issueComment","pull","push","watch", "release"]

spark = SparkSession.builder\
    .appName("test")\
    .config("spark.sql.warehouse.dir", "/user/hive/warehouse")\
    .config("spark.mongodb.input.uri", "mongodb://master02:37017")\
    .config("spark.mongodb.output.uri", "mongodb://master02:37017")\
    .config("spark.jars.packages", "org.mongodb.spark:mongo-spark-connector_2.12:3.0.2")\
    .enableHiveSupport()\
    .getOrCreate()

hive_context = HiveContext(spark.sparkContext)

# input: df: dataframe, table: single table name
def iodatabase(wdf, table, htable, to_mongo=True, to_mysql=True, to_hive=True, show_count=True):
    if to_hive:
        # write data to hive
        # check if table exists
        try:
            wdf.createOrReplaceTempView("tmptable")
            s = spark.sql("show tables in default like '{}'".format(htable))
            flag = len(s.collect())
            if flag:
                logger.info("hive repo {} exist".format(htable))
                hive_context.sql("insert into default.{} select * from tmptable".format(htable))
            else:
                logger.info("hive repo {} not exist".format(htable))
                hive_context.sql("create table IF NOT EXISTS default.{} select * from tmptable".format(htable))
        except:
            logger.error("write data to hive's table {} failed".format(htable))
            pass
        


    if to_mongo:
        if show_count:  
            try:
                # read shcema from each mongodb collection
                rdf = spark.read.format("mongo").option("database", mongodb_name).option("collection", table).load()
                # count documents in each collection now
                logger.info("count of {} is {}".format(table, rdf.count()))
            except:
                logger.error("read data from mongodb's collections {} failed".format(table))
                pass

        # write data to mongodb's collections
        wdf.write.format("mongo").mode("append").option("database", mongodb_name).option("collection", table).save()
        logger.info("write data to mongodb's collections {} successfully".format(table))


    if to_mysql:
        if show_count:
            try:
                # read schema from mysql
                rdf = spark.read.format("jdbc").option(
                    url="jdbc:mysql://worker02:3306/github",
                    driver="com.mysql.cj.jdbc.Driver",
                    dbtable="(select count(*) from {}) as {}".format(table, table),
                    user="root",
                    password="123456"
                ).load()
                # count documents in each collection now
                logger.info("count of {} is {}".format(table, rdf.count()))
            except:
                logger.error("read data from mysql's table {} failed".format(table))
                pass

        # write data to mysql
        logger.info("write data to mysql's table {} successfully".format(table))

        wdf.write.format("jdbc")\
            .option("url", "jdbc:mysql://worker02:3306/github")\
            .option("driver", "com.mysql.cj.jdbc.Driver")\
            .option("dbtable", table)\
            .option("user", "root")\
            .option("password", "123456")\
            .mode("append")\
            .save()



def getUserActivity():
    timetable_df = spark.sql("select * from default.timestable")
    maxtimestamp = timetable_df.select(F.max("timestamp_d").alias("timestamp_d"))
    timetable_df = timetable_df.select(timetable_df.time_hour, timetable_df.timestamp_d)
    timetable_df = timetable_df.join(maxtimestamp, maxtimestamp.timestamp_d==timetable_df.timestamp_d, 'inner')
    timetable_df = timetable_df.select(timetable_df.time_hour).limit(1)


    t_timetable_df = timetable_df.withColumn("id", F.lit(1))
    t_timetable_df = t_timetable_df.withColumnRenamed("time_hour", "created_at")
    # convert the time_hour to timestamp
    t_timetable_df = t_timetable_df.withColumn("created_at", F.to_timestamp(t_timetable_df.created_at, "yyyy-MM-dd-HH"))

    pushTable_df = spark.sql("select id as active_id,time,actor_id from default.pushTable")
    pushTable_df = pushTable_df.join(timetable_df, timetable_df.time_hour == pushTable_df.time).drop(timetable_df.time_hour).drop(pushTable_df.time)
    # print("==================================")
    # print(pushTable_df.filter(pushTable_df.active_id == "69688279").count())

    user = spark.sql("select id,login,company,followers,following,location,public_repos from default.users")
    # print("====================================")
    # print(user.select(user.location).distinct().collect())
    # print("====================================")

    user_rdd = user.rdd
    user_rdd = user_rdd.map(lambda x : (x[0], (x[1], x[2], x[3], x[4], x[5], x[6])))
    user_rdd = user_rdd.reduceByKey(lambda a, b: b)
    user_rdd = user_rdd.map(lambda x : (x[0], x[1][0], x[1][1], x[1][2], x[1][3], x[1][4], x[1][5]))

    user_df = spark.createDataFrame(user_rdd, ["id","login","company","followers","following","location","public_repos"])
    # print("====================================")
    # print(user_df.select(user_df.location).distinct().collect())
    # print("====================================")

    # mixed table contains many imformation to do more group on this dataframe
    activity_mix = user_df.join(pushTable_df, user_df.id == pushTable_df.actor_id).drop(pushTable_df.actor_id)
    activity_mix = activity_mix.distinct()



    # create a table contains the top 100 active users in this hour
    acivityGroupByUserid = activity_mix.groupBy('id').count()
    acivityGroupByUserid = acivityGroupByUserid.join(user_df, user_df.id == acivityGroupByUserid.id).drop(acivityGroupByUserid.id)
    topActiveUser = acivityGroupByUserid.filter(acivityGroupByUserid.public_repos > 0).filter(acivityGroupByUserid.public_repos != 0).orderBy("count", ascending=0)
    # rename count to activity_cnt
    topActiveUser = topActiveUser.withColumnRenamed("count", "activity_cnt")
    topActiveUser = topActiveUser.withColumn("updated_at", F.lit(datetime.now().strftime("%Y-%m-%d %H:%M:%S")).cast("timestamp"))
    topActiveUser = topActiveUser.withColumn("id", F.lit(1)).join(t_timetable_df, "id", "inner").drop("id")
    # topActiveUser.show(20)

    # define funtion to transform location to do better group
    def changelocation(s):
        s = s.strip()
        if "," in s:
            s = s.split(',')
            return s[-1].strip()
        return s

    # create a table contains the top 100 active location in this hour
    changelocationUDF = F.udf(changelocation, StringType())
    topActiveRegion = activity_mix.filter(activity_mix.location != "None")
    topActiveRegion = topActiveRegion.withColumn("location", changelocationUDF(topActiveRegion.location))
    topActiveRegion = topActiveRegion.groupBy('location').count().orderBy("count", ascending=0)
    topActiveRegion = topActiveRegion.withColumn("updated_at", F.lit(datetime.now().strftime("%Y-%m-%d %H:%M:%S")).cast("timestamp"))
    topActiveRegion = topActiveRegion.withColumnRenamed("count", "activity_cnt")
    # topActiveRegion.show(20)

    # create a table contains the top 100 active company in this hour
    topActiveCompany = activity_mix.filter(activity_mix.company != "None").groupBy('company').count().orderBy("count", ascending=0)
    topActiveCompany = topActiveCompany.withColumn("updated_at", F.lit(datetime.now().strftime("%Y-%m-%d %H:%M:%S")).cast("timestamp"))
    topActiveCompany = topActiveCompany.withColumnRenamed("count", "activity_cnt")
    # topActiveCompany.show(20)

    iodatabase(topActiveUser, "topActiveUser", "dws_userTopActiveUser", to_mongo=True, to_mysql=True, to_hive=True, show_count=False)
    iodatabase(topActiveRegion, "topActiveRegion", "dws_userTopActiveRegion", to_mongo=True, to_mysql=True, to_hive=True, show_count=False)
    iodatabase(topActiveCompany, "topActiveCompany", "dws_userTopActiveCompany", to_mongo=True, to_mysql=True, to_hive=True, show_count=False)


if __name__ == '__main__':

    getUserActivity()

    
