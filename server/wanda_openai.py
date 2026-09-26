import os
from pyexpat.errors import messages
from openai import AzureOpenAI
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Example: get your OpenAI API key
subscription_key = os.getenv("OPENAI_API_KEY")

endpoint = "https://wanda-openai-001.openai.azure.com/"
model_name = "gpt-4.1"
deployment = "gpt-4.1"


client = AzureOpenAI(
    api_version="2024-12-01-preview",
    azure_endpoint=endpoint,
    api_key=subscription_key,
)


def chat_completion(chat_history, user_input, context=""):
    """Appends the user's message and the reply to `chat_history` and returns it.

    `context` describes the user's Mac right now (time, music, app in use). It is sent
    with this request only and not saved, so it doesn't pile up in the history.
    """
    messages = chat_history
    if not any(m.get("role") == "system" for m in messages):
        messages.insert(0, {"role": "system", "content": "You are a helpful assistant."})
    messages.append({"role": "user", "content": user_input})

    request_messages = list(messages)
    if context:
        request_messages.insert(-1, {
            "role": "system",
            "content": "Current state of the user's Mac (use it only if relevant):\n" + context,
        })
    response = client.chat.completions.create(
        # stream=True,
        messages=request_messages,
        max_completion_tokens=13107,
        temperature=1.0,
        top_p=1.0,
        frequency_penalty=0.0,
        presence_penalty=0.0,
        model=deployment,
    )
    messages.append({"role": "assistant","content": response.choices[0].message.content})
    return messages


def end_chat():
    print("Ending GenAI chat session.2")
    client.close()
