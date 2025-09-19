from fastapi import FastAPI
import os
from models.Wanda_DB_Mongo import *
import uuid
import datetime
from wanda_openai import *

random_id = str(uuid.uuid4())
app = FastAPI()

@app.get("/")
def read_root():
    return {"message": "Welcome to Wanda Voice AI Assistant!"}
#Local App Calls
@app.get("/open")
def open_app(app: str):
    try:
        app_name = app.replace("\%20", " ")
        print(app_name.title())
        os.system('open -a ' + app_name.title() + '.app')
        return {'response': ('Opening ' + app_name.title())}
    except Exception:
        return {'response': ('App not found')}
@app.get("/close")
def close_app(app: str):
    try:
        app_name = app.replace("+", " ")
        # For Spotify and most macOS apps, process name is lowercase
        process_name = app_name.lower()
        # Try pkill with both lower and title case
        result = os.system(f'pkill -f "{process_name}"')
        if result != 0:
            # Try with .app extension
            result = os.system(f'pkill -f "{process_name}.app"')
        if result == 0:
            return {'response': f'Closing {app_name.title()}'}
        else:
            return {'response': f'Could not close {app_name.title()}'}
    except Exception:
        return {'response': ('App not found')}
@app.get("/custom_command/{name}")
def custom_command(name: str):
    # Make db call to get custom command for app
    # Run custom command
    command = Commands.find_one({"name": name})
    if command:
        runscript = command.script
        os.system(runscript)
        return {"status": f"Executing custom command for {name}"}
    else:
        return {"error": "Custom command not found"}

#GenAI Calls
@app.get("/genAI/chat")
def init_chat(user_input: str,id: str=""):
    # Add logic to create GenAI application
    response = None
    try:
        if id == "":
            id = random_id
            chat_history = []
            response = chat_completion(chat_history, user_input)
            add_chat_history(chat=response,id=id)
        else:
            chat_history = get_chat_history(id)
            print(chat_history.chat)
            response = chat_completion(chat_history.chat, user_input)
            update_chat_history(chat=response,id=id)
    except Exception as e:
        print(f"Error retrieving chat history: {e}")
        response = [{"content": "Error: " + str(e)}]

    return {"chat_id": id, "response": response[-1]["content"]}
@app.get("/genAI/end")
def end_chat():
    # Add logic to end GenAI application
    print("Ending GenAI chat session.")
    end_chat()
    return {"status": f"Ending GenAI"}

#DB 
# Chat_History
@app.get("/db/chat_history")
def get_chat_history(id: str):
    # Add logic to retrieve chat history for a user
    chat = Chat_History.find_one({"id": id})
    return chat if chat else []
@app.delete("/db/chat_history/delete")
def delete_chat_history(id: str):
    # Add logic to delete chat history for a user
    Chat_History.delete_one({"id": id})
    return {"status": f"Deleted chat history for user {id}"}
@app.post("/db/chat_history/add")
def add_chat_history(chat: str,id: str):
    # Add logic to add a message to chat history for a user
    Chat_History.insert_one({"chat": chat,"id": id, "dateCreated": datetime.datetime.now()})
    return {"status": f"Added message to chat history for {id}"}
@app.put("/db/chat_history/update")
def update_chat_history(chat: str,id: str):
    # Add logic to update a message in chat history for a user
    Chat_History.update_one({"id": id}, {"$set": {"chat": chat, "dateUpdated": datetime.datetime.now()}})
    return {"status": f"Updated message in chat history for {id}"}

#Users Collection
@app.get("/db/users")
def get_users():
    users = Users.find()
    return {"users": [user.__dict__ for user in users]}
@app.get("/db/user")
def get_user(name: str, key: str):
    user = Users.find_one({"name": name, "key": key})
    if user:
        # Serialize user object safely
        return {"user": {
            "id": user.id,
            "name": user.name,
            "key": user.key,
            "dateCreated": str(user.dateCreated),
            "dateUpdated": str(user.dateUpdated)
        }}
    else:
        return {"error": "User not found"}   
@app.post("/db/user/add")
def add_user(name: str, key: str, role: str):
    # Define add_user_to_db function here or import it from models.Wanda_DB_Mongo
    try:
        Users.insert_one({"name": name, "role": role, "key": key, "id": random_id, "dateCreated": datetime.datetime.now(), "dateUpdated": datetime.datetime.now()})
        return {"status": f"Added user to database: {name}"}
    except Exception as e:
            return {"status": f"Failed to add user to database: {e}"}
@app.delete("/db/user/delete/{id}")
def delete_user(id: str):
    # Add logic to delete user from database
    try:
        Users.delete_one({"id": id})
        return {"status": f"Deleted user from database: {id}"}
    except Exception as e:
        return {"status": f"Failed to delete user from database: {e}"}
@app.delete("/db/users/delete")
def delete_all():
    # Add logic to delete user from database
    try:
        Users.delete_all_except({"role": {"$ne": "admin"}})
        return {"status": f"Deleted all users except admins"}
    except Exception as e:
        return {"status": f"Failed to delete users from database: {e}"}
@app.put("/db/user/update/{id}")
def update_user(id:str, new_name: str,new_key: str):
    # Add logic to update user in database
    try:
        Users.update_one({"id": id}, {"$set": {"name": new_name, "key": new_key}})
    except Exception as e:
        return {"status": f"Failed to update user: {e}"}
    return {"status": f"Updating user to {new_name}"}

#Commands Collection
@app.get("/db/commands")
def get_commands():
    commands = Commands.find()
    return {"commands": [command.__dict__ for command in commands]}
@app.post("/db/commands/add")
def add_command(name: str, script: str, variables: str):
    # Example implementation: add command to Commands collection
    try:
        Commands.insert_one({"name": name, "script": script, "variables": variables, "dateCreated": datetime.datetime.now(), "dateUpdated": datetime.datetime.now()})
        return {"status": f"Added command to database: {name}"}
    except Exception as e:
        return {"status": f"Failed to add command to database: {e}"}
@app.delete("/db/commands/delete")
def delete_command(command: str):
    # Add logic to delete command from database
    return {"status": f"Deleting command from database: {command}"}
@app.put("/db/commands/update")
def update_command(old_command: str, new_command: str):
    # Add logic to update command in database
    return {"status": f"Updating command from {old_command} to {new_command}"}
