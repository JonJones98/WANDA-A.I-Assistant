from unittest import result
from flask import flash
import pymongo
import os
import sys
from bson import ObjectId
from dotenv import load_dotenv
load_dotenv()
try:
  client = pymongo.MongoClient(os.getenv("MongoDB_Connection_String"))

# return a friendly error if a URI error is thrown 
except pymongo.errors.ConfigurationError:
  print("An Invalid URI host error was received. Is your Atlas host name correct in your connection string?")
  sys.exit(1)

db = client.WandaDB

# use a collection named
Commands_collection = db["Commands"]
Users_collection  = db["Users"]
Chat_History_collection  = db["Chat_History"]

class Commands:
    def __init__(self, data):
        #self.id=data["commandId"]
        self.name = data["name"]
        self.script = data["script"]
        self.variables = data["variables"]
        # self.dateCreated = data["dateCreated"]
        # self.dateUpdated = data["dateUpdated"]
    #Read
    @classmethod
    def find(cls):
        results = Commands_collection.find()
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def find_one(cls,query):
        results = Commands_collection.find_one(query)
        return cls(results) if results else None
    #Update
    @classmethod
    def update_many(cls,query):
        results = Commands_collection.update_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def update_one(cls,query):
        results = Commands_collection.update_one(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    #Create
    @classmethod
    def insert_many(cls,query):
        results = Commands_collection.insert_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def insert_one(cls,query):
        results = Commands_collection.insert_one(query)
        return results
    #Delete
    @classmethod
    def delete_many(cls,query):
        results = Commands_collection.delete_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def delete_one(cls,query):
        results = Commands_collection.delete_one(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
class Users:
    def __init__(self, data):
        self.id = data["_id"]
        self.id = data["id"]
        self.name = data["name"]
        self.key = data["key"]
        self.dateCreated = data.get("dateCreated")
        self.dateUpdated = data.get("dateUpdated")
    #Read
    @classmethod
    def find(cls):
        results = Users_collection.find()
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def find_one(cls, query):
        result = Users_collection.find_one(query)
        if result:
            return cls(result)
        return None
    #Update
    @classmethod
    def update_many(cls,query):
        results = Users_collection.update_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def update_one(cls,filter,update):
        results = Users_collection.update_one(filter, update)
        return results
    #Create
    @classmethod
    def insert_many(cls,query):
        results = Users_collection.insert_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def insert_one(cls,query):
        results = Users_collection.insert_one(query)
        return results
    #Delete
    @classmethod
    def delete_many(cls,query):
        results = Users_collection.delete_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def delete_one(cls,query):
        results = Users_collection.delete_one(query)
        return results
    @classmethod
    def delete_all_except(cls,query):
        results = Users_collection.delete_all(query)
        return results
class Chat_History:
    def __init__(self, data):
        self.id = data["_id"]
        self.id = data["id"]
        self.chat = data["chat"]
        self.dateCreated = data.get("dateCreated")
    #Read
    @classmethod
    def find(cls):
        results = Chat_History_collection.find()
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def find_one(cls, query):
        result = Chat_History_collection.find_one(query)
        if result:
            return cls(result)
        return None
    #Update
    @classmethod
    def update_many(cls,query):
        results = Chat_History_collection.update_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def update_one(cls,filter,update):
        results = Chat_History_collection.update_one(filter, update)
        return results
    #Create
    @classmethod
    def insert_many(cls,query):
        results = Chat_History_collection.insert_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def insert_one(cls,query):
        results = Chat_History_collection.insert_one(query)
        return results
    #Delete
    @classmethod
    def delete_many(cls,query):
        results = Chat_History_collection.delete_many(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
    @classmethod
    def delete_one(cls,query):
        results = Chat_History_collection.delete_one(query)
        return results
    @classmethod
    def delete_all_except(cls,query):
        results = Chat_History_collection.delete_all(query)
        return results
class Validate:
    @staticmethod
    def validate_info(QRinfo):
        is_valid = True # we assume this is true
        if len(QRinfo['url']) < 1:
            flash("*URL field is missing")
            is_valid = False
        if len(QRinfo['filename']) < 1:
            flash("*Filename is missing")
            is_valid = False
        if (QRinfo['formattype'])in "Select Format":
            flash("*Select Format type")
            is_valid = False
        return is_valid


