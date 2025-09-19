from unittest import result
from config.mysqlconnection import connectToMySQL
from config.mongodbConnnect import connectToMongoDB
from flask import flash
class Commands:
    def __init__(self, data):
        self.id=data["commandId"]
        self.name=data["commandName"]
        self.script=data["script"]
        self.variables=data["variables"]
        self.dateCreated=data["dateCreated"]
        self.dateUpdated=data["dateUpdated"]
    @classmethod
    def get_all(cls):
        query = "SELECT * FROM Commands;"
        results = connectToMongoDB('Wanda_Commands').query_db(query)
        data = []
        for result in results:
            data.append(cls(result))
        return data
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


