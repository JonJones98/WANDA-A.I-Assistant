 #client = pymongo.MongoClient(mongodb+srv://jonathanjones618:cXt4iYVsFJNLBSUN@cluster0.rhcjc3k.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0)
import pymongo
import sys

# Replace the placeholder data with your Atlas connection string. Be sure it includes
# a valid username and password! Note that in a production environment,
# you should not store your password in plain-text here.

try:
  client = pymongo.MongoClient("mongodb+srv://jonathanjones618:cXt4iYVsFJNLBSUN@cluster0.rhcjc3k.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0")
  
# return a friendly error if a URI error is thrown 
except pymongo.errors.ConfigurationError:
  print("An Invalid URI host error was received. Is your Atlas host name correct in your connection string?")
  sys.exit(1)

# use a database named "myDatabase"
db = client.WandaDB

# use a collection named "recipes"
Commands = db["Commands"]
Users = db["Users"]
