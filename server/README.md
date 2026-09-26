# Wanda Server

This folder contains the backend server for the Wanda Voice AI Assistant. It provides API endpoints for voice-driven interactions and application management on macOS.

## Structure

- `main.py` — Main FastAPI application with API endpoints
- `wanda_openai.py` — OpenAI Azure integration for AI chat capabilities
- `wanda_tts.py` — Local text-to-speech with Kokoro
- `tts_models/` — Kokoro model files (downloaded, ignored by Git)
- `requirements.txt` — Python dependencies list
- `models/` — Database models and schemas
  - `Wanda_DB_Mongo.py` — MongoDB models and operations
- `wandaenv/` — Python virtual environment (ignored by Git)

## Features

- **Voice Command Processing**: Handle voice-driven interactions
- **AI Integration**: Azure OpenAI GPT-4 integration for intelligent responses
- **Database Support**: MongoDB and MySQL support for data persistence
- **macOS App Control**: Open and close macOS applications via API
- **Custom Commands**: Store and execute custom user commands
- **FastAPI Framework**: Modern, fast, async API with automatic documentation
- **Chat History**: Maintain conversation history with AI assistant
- **Natural Voices**: Kokoro text-to-speech runs locally, free and offline

## Prerequisites

- Python 3.8 or higher
- macOS (for application control features)
- MongoDB Atlas account (for database)
- Azure OpenAI API key

## Setup

1. **Clone the repository and navigate to server folder**:
    ```sh
    cd server
    ```

2. **Create and activate a virtual environment**:
    ```sh
    python3 -m venv wandaenv
    source wandaenv/bin/activate
    ```

3. **Install dependencies**:
    ```sh
    pip install -r requirements.txt
    ```

4. **Environment Configuration**:
    Create a `.env` file in the server directory with the following variables:
    ```env
    OPENAI_API_KEY=your_azure_openai_api_key_here
    MONGODB_CONNECTION_STRING=your_mongodb_connection_string
    ```

5. **Download the Kokoro voice model** (about 340 MB, one time):
    ```sh
    mkdir -p tts_models
    curl -L -o tts_models/kokoro-v1.0.onnx https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
    curl -L -o tts_models/voices-v1.0.bin https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
    ```
    Without these files the server still runs; the app falls back to Apple voices.

## Running the Server

1. **Activate virtual environment** (if not already active):
    ```sh
    source wandaenv/bin/activate
    ```

2. **Start the FastAPI server** (ensure you are in the `server` directory):
    ```sh
    uvicorn main:app --reload
    ```
    *If you are in the project root, use:*
    ```sh
    uvicorn server.main:app --reload
    ```

3. **Access the API**:
    - API Base URL: [http://127.0.0.1:8000](http://127.0.0.1:8000)
    - Interactive API Documentation: [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)
    - Alternative API Docs: [http://127.0.0.1:8000/redoc](http://127.0.0.1:8000/redoc)

## Dependencies

The project uses the following main dependencies:

- **FastAPI**: Modern web framework for building APIs
- **Uvicorn**: ASGI server for FastAPI
- **OpenAI**: Azure OpenAI integration
- **PyMongo**: MongoDB driver for Python
- **Flask**: Web framework (used alongside FastAPI)
- **python-dotenv**: Environment variable management
- **BSON**: Binary JSON for MongoDB

For a complete list, see `requirements.txt`.

## Development

To contribute to the server:

1. Install development dependencies
2. Follow Python PEP 8 style guidelines
3. Test API endpoints using the automatic documentation at `/docs`
4. Ensure MongoDB connection is properly configured

## Configuration

- **Database**: Configure MongoDB and MySQL connections in the `config/` folder
- **OpenAI**: Set up Azure OpenAI endpoint and API key in environment variables
- **Environment Variables**: Use `.env` file for sensitive configuration (ignored by Git)

## Troubleshooting

- **MongoDB Connection Issues**: Check your connection string and network access
- **OpenAI API Errors**: Verify your Azure OpenAI API key and endpoint
- **macOS App Control**: Ensure proper permissions for system app control
- **No Kokoro voices in the app**: Check that `tts_models/` has both files and that `GET /tts/voices` works at `/docs`

## License

MIT
