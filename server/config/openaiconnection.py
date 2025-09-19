import os
from openai import AzureOpenAI

client = AzureOpenAI(
    api_version="2024-12-01-preview",
    azure_endpoint="https://wanda-openai-001.openai.azure.com/",
    api_key=subscription_key,
)
