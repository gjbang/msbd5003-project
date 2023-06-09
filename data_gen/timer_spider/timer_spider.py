from functools import partial
from itertools import repeat
from apscheduler.schedulers.background import BackgroundScheduler
from concurrent.futures import ThreadPoolExecutor, as_completed
import requests

import os
import gzip
import time
import glob
import json
import datetime
import shutil

import pymysql

import logging
from log import Logger

from construct_sql import cons_user_sql, cons_repo_sql,get_repo_insert_sql, get_user_insert_sql

temp_data_dir = "/tmp/data"
flume_data_dir = "/opt/data/flume"

# temp_data_dir = "./temp_data"
# flume_data_dir = "./temp_flume_data"

# current_mysql_json_name = ""
# last_mysql_json_name = ""
# last_flume_json_name = ""

download_cnt_main = 0
import_mysql_cnt_main = 0
import_flume_cnt_main = 0

new_files = []
auth_tokens = []
current_token_id = 0

call_api_batch_size = 10
write_flume_batch_size = 1000

db_conn = pymysql.connect(
    host="worker02",
    port=3306,
    user="root",
    password="123456",
    database="github",
    charset="utf8mb4"
)

# db_conn = pymysql.connect(
#     host="localhost",
#     port=3306,
#     user="root",
#     password="heikediguo",
#     database="github",
#     charset="utf8mb4"
# )

logger = Logger("./logs/main.log", logging.DEBUG, __name__).getlog()


# decompress gzip file to json file
# execute after importing corresponding user and repo data into mysql
# decompress json to flume directory
def decompress_gzip(gzip_path, json_path):
    # decompress gzip file
    with gzip.open(gzip_path, 'rb') as f_in:
        with open(json_path, 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)
    # delete gzip file
    os.remove(gzip_path)


def download_json_data(download_cnt=1):
    global current_mysql_json_name, download_cnt_main

    logger.info(" == start download json data == ")
    
    # read downloaded json list from record log file
    # only record json which has been import to mysql,so it will be newer then data in flume
    if os.path.exists("./logs/downloaded_files.log"):
        with open("./logs/downloaded_files.log", "r") as f:
            downloaded_files = f.readlines()
    else:
        downloaded_files = []
        # create downloaded_files.log
        with open("./downloaded_files.log", "w") as f:
            pass
    
    # get current time
    now_time = datetime.datetime.now()
    interval, fetch_cnt = 0, 0
    while fetch_cnt < download_cnt:
        target_time = (now_time - datetime.timedelta(hours=interval)).strftime('%Y-%m-%d-%H')
        
        if target_time + "\n" not in downloaded_files:
            # construct target url
            target_url = 'https://data.gharchive.org/' + target_time + '.json.gz'
            r = requests.head(target_url)
            if r.status_code == 200:
                logger.info("find new file " + target_time + ", try downloading ... ")

                # check if file has been downloaded
                if os.path.exists(os.path.join(temp_data_dir, target_time + ".json.gz")):
                    logger.warning("file " + target_time + " has been downloaded")
                else:
                    # try to download file
                    try:
                        resp = requests.get(target_url, stream=True, timeout=10)
                        resp.raise_for_status()
                        with open(os.path.join(temp_data_dir, target_time + ".json.gz"), "wb") as f:
                            for chunk in resp.iter_content(chunk_size=1024):
                                f.write(chunk)
                        # add to new_files
                        new_files.append(target_time)
                    except Exception as e:
                        logger.error("download file " + target_time + " failed, error: " + str(e))
                    else:
                        logger.info("download file " + target_time + " success")
                        # only record the 1st or the lastest file name A, which wiil query and import to mysql
                        # # another earlest file name B will only import to flume
                        # records downloaded file into downloaded_files.log
                        with open("./logs/downloaded_files.log", "a") as f:
                            f.write(target_time + "\n")
                fetch_cnt += 1
                current_mysql_json_name = target_time
        interval += 1

    download_cnt_main += download_cnt
    logger.info(" == end download json data == ")


# generate json object from gzip file
def generate_gzip_json(gzip_path):
    with gzip.open(gzip_path, 'rb') as f:
        for line in f:
            yield json.loads(line)


def call_api_to_mysql(cjson_list):
    global current_token_id, auth_tokens

    # logger.debug(" == start call api to mysql, the # of json: " + str(len(cjson_list)) + " == ")

    user_sql = get_user_insert_sql()
    repo_sql = get_repo_insert_sql()

    user_values = []
    repo_values = []

    query_term = {
        "user_data": ['actor', 'login','https://api.github.com/users/{}'],
        "repo_data": ['repo','name','https://api.github.com/repos/{}']
    }

    limited = False
    limited_token_id = 0

    for cjson in cjson_list:
        for key, param in query_term.items():
            url = param[2].format(cjson[param[0]][param[1]])
            headers = {'Authorization': 'Bearer ' + auth_tokens[current_token_id]}

            try:
                resp = requests.get(url, headers=headers, timeout=10)
                resp.raise_for_status()
            except Exception as e:
                if resp.status_code == 403:
                    if limited and limited_token_id == current_token_id:
                        time.sleep(120)
                    if not limited:
                        limited_token_id = current_token_id
                        limited = True
                    current_token_id = (current_token_id + 1) % len(auth_tokens)
                    logger.warning("token " + str(current_token_id) + " has been used up, change to next token")
                else:
                    logger.error("call github api failed, error: " + str(e))
            else:
                limited = False
                # logger.debug("call github api success, url: " + url)
                # get user data for insert sql
                if key == "user_data":
                    user_values += cons_user_sql([resp.json()])
                    # print(len(user_values))    
                elif key == "repo_data":
                    repo_values += cons_repo_sql([resp.json()])
                    # print(repo_values)
        # ccj += 1
        # logger.debug(" == call api to mysql, the # of json: " + str(ccj) +"/" + str(len(cjson_list)) + " == ")

        
    
    logger.debug(" == start to insert mysql == ")
    # logger.debug(user_values)
    # execute insert sql
    cursor = db_conn.cursor()
    try:
        # check if mysql connection is alive, if not, reconnect
        db_conn.ping(reconnect=True)
        cursor.executemany(user_sql, user_values)
        cursor.executemany(repo_sql, repo_values)
        db_conn.commit()
    except Exception as e:
        logger.error("insert user or repo data failed, error: " + str(e))
        db_conn.rollback()
    finally:
        cursor.close()




def process_json_mysql():
    global import_mysql_cnt_main

    mysql_imported_files = []
    if os.path.exists("./logs/mysql_imported.log"):
        with open("./logs/mysql_imported.log", "r") as f:
            for line in f.readlines():
                mysql_imported_files.append(line[:-1])
    

    # wait for download_json_data to download new json file
    while True:
        # get the name of lastest json file downloaded 
        if os.path.exists("./logs/downloaded_files.log"):
            with open("./logs/downloaded_files.log", "r") as f:
                current_mysql_json_name = f.readlines()[-1][:-1]
        else:
            current_mysql_json_name = ""

        if current_mysql_json_name != "" and current_mysql_json_name not in mysql_imported_files:
            break
        else:
            logger.warning("current_mysql_json_name is empty, wait 60s")
            time.sleep(60)

    logger.info(" == start import json data into mysql == ")
    logger.info("The lastest json file is " + current_mysql_json_name)

    # == import meta data into mysql == #
    # query user and repo data by using json's actor and repo field
    with ThreadPoolExecutor(max_workers=10) as executor:
        json_cnt = 0
        json_list = []
        for cjson in generate_gzip_json(os.path.join(temp_data_dir, current_mysql_json_name + ".json.gz")):
            json_cnt += 1
            json_list.append(cjson)
            if json_cnt == call_api_batch_size:
                logger.debug("submit " + str(call_api_batch_size) + " json data to thread pool")
                executor.submit(call_api_to_mysql, json_list)
                json_cnt = 0
                json_list = []
                time.sleep(2)
        
        if json_cnt > 0:
            executor.submit(call_api_to_mysql, json_list)


    # recorded all json which has been imported into mysql
    with open("./logs/mysql_imported.log", "a") as f:
        f.write(current_mysql_json_name + "\n")

    logger.info(" == end import json data to mysql " + current_mysql_json_name + " == ")
    import_mysql_cnt_main += 1






# write archieve data to json file in flume directory
# delete all urls property in json and serialize payload to string
def import_json_to_flume(cjson_list, opath):
    for cjson in cjson_list:
        # modify json slightly to decrease the size of json
        stack = [cjson]
        while stack:
            obj = stack.pop()
            if isinstance(obj, dict):
                for key in list(obj.keys()):
                    # delete all attributes which is "url" in json
                    if isinstance(obj[key], str) and ('http://' in obj[key] or 'https://' in obj[key]):
                        del obj[key]
                    # delete empty attributes : [], {}
                    elif isinstance(obj[key], list) and len(obj[key]) == 0:
                        del obj[key]
                    elif isinstance(obj[key], dict) and len(obj[key]) == 0:
                        del obj[key]
                    else:
                        stack.append(obj[key])
            elif isinstance(obj, list):
                stack.extend(obj)

    # stack = [cjson]
    # while stack:
    #     obj = stack.pop()
    #     if isinstance(obj, dict):
    #         for key in list(obj.keys()):
    #             # delete all attributes which is "url" in json
    #             if key == 'payload':
    #                 obj[key] = json.dumps(obj[key])
    #             else:
    #                 stack.append(obj[key])
    #     elif isinstance(obj, list):
    #         stack.extend(obj)


    # logger.debug(" == start to append json to flume directory == ")
    # logger.debug(cjson)

    # append json to flume directory
    with open(opath, "a") as f:
        for cjson in cjson_list:
            f.write(json.dumps(cjson) + "\n")



def process_json_flume():
    global import_flume_cnt_main

    flume_imported_files = []
    if os.path.exists("./logs/flume_imported.log"):
        with open("./logs/flume_imported.log", "r") as f:
            for line in f.readlines():
                flume_imported_files.append(line[:-1])

    current_flume_json_name = ""
    # wait for process_json_mysql to import new json file
    while True:
        down_files = []
        # if os.path.exists("./logs/mysql_imported.log"):
        #     with open("./logs/mysql_imported.log", "r") as f:
        #         for line in f.readlines():
        #             mysql_imported_files.append(line[:-1])

        if os.path.exists("./logs/downloaded_files.log"):
            with open("./logs/downloaded_files.log", "r") as f:
                for line in f.readlines():
                    down_files.append(line[:-1])

        # if file is in mysql_imported_files, but not in flume_imported_files, then import it into flume
        if len(list(set(down_files) - set(flume_imported_files))) > 0:
            current_flume_json_name = list(set(down_files) - set(flume_imported_files))[-1]
            break
        else:
            logger.warning("current_flume_json_name is empty, wait 60s")
            time.sleep(60)

    # create target json file
    logger.info(" == start import json data into flume == ")
    if not os.path.exists(os.path.join(flume_data_dir, current_flume_json_name + ".json")):
        with open(flume_data_dir+"/"+current_flume_json_name + ".json", "w") as f:
            f.write("")


    # == import data into flume == #
    with ThreadPoolExecutor(max_workers=10) as executor:
        # use map() to apply the function to each item coming from generate_gzip_json()
        # executor.map(import_json_to_flume, generate_gzip_json(os.path.join(temp_data_dir, current_flume_json_name + ".json.gz")), repeat(os.path.join(flume_data_dir, current_flume_json_name + ".json")))
        json_cnt = 0
        json_list = []
        for cjson in generate_gzip_json(os.path.join(temp_data_dir, current_flume_json_name + ".json.gz")):
            json_cnt += 1
            json_list.append(cjson)
            if json_cnt == write_flume_batch_size:
                logger.debug("[flume] submit " + str(write_flume_batch_size) + " json data to thread pool")
                executor.submit(import_json_to_flume, json_list, flume_data_dir +"/"+ current_flume_json_name + ".json")
                json_cnt = 0
                json_list = []
                time.sleep(2)

        if json_cnt > 0:
            executor.submit(import_json_to_flume, json_list, flume_data_dir +"/"+ current_flume_json_name + ".json")


    # record all json which has been imported into flume
    with open('./logs/flume_imported.log', "a") as f:
        f.write(current_flume_json_name + "\n")

    # delete last json file
    with open('./logs/last_flume_json_name.log', "r") as f:
        last_flume_json_name = f.readline()
    if last_flume_json_name != "":
        os.remove(os.path.join(flume_data_dir, last_flume_json_name + ".json"))
    with open('./logs/last_flume_json_name.log', "w") as f:
        f.write(current_flume_json_name)

    logger.info(" == end import json data to flume " + current_flume_json_name + " == ")
    import_flume_cnt_main += 1



if __name__ == '__main__':
    # check if log directory exists
    if not os.path.exists("./logs"):
        os.makedirs("./logs")

    # chekc if log file exists
    if not os.path.exists("./logs/main.log"):
        with open("./logs/main.log", "w") as f:
            f.write("")

    # check if temp_data_dir exists
    if not os.path.exists(temp_data_dir):
        os.makedirs(temp_data_dir)

    # check if flume_data_dir exists
    if not os.path.exists(flume_data_dir):
        os.makedirs(flume_data_dir)

    # check if DB connection : db_conn is available
    if not db_conn:
        logger.error("DB connection failed, exit")
        exit(1)

    # init auth token list
    with open("./auth_token.txt", "r") as f:
        for line in f.readlines():
            auth_tokens.append(line.strip())

    # init first part data by execute download task immediately
    download_json_data()

    # Create a scheduler
    scheduler = BackgroundScheduler()
    # Schedule the download function to run every hour
    scheduler.add_job(download_json_data, 'interval', minutes=10, misfire_grace_time=None)
    # Schedule the processing function to run every hour, five minutes after the download function
    scheduler.add_job(process_json_mysql, 'interval', minutes=1, misfire_grace_time=None)
    # Schedule the processing function to run every hour, five minutes after the download function
    scheduler.add_job(process_json_flume, 'interval', minutes=1, misfire_grace_time=None)

    try:
        # Start the scheduler
        scheduler.start()
    except (KeyboardInterrupt, SystemExit):
        scheduler.shutdown()

    # Wait for the scheduler to finish executing
    while True:
        time.sleep(600)
        logger.info("== Main Thread for 300s, then check again. ==")
        logger.info("**** import_mysql_cnt_main: " + str(import_mysql_cnt_main))
        logger.info("**** import_flume_cnt_main: " + str(import_flume_cnt_main))
        logger.info("**** download_json_cnt_main: " + str(download_cnt_main))


    # Shut down the scheduler when exiting the application
    scheduler.shutdown()
