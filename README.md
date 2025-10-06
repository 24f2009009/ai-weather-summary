# Weather Report Summarizer API

A FastAPI-based service that provides AI-powered, human-friendly weather summaries using Open-Meteo weather data and Google's Gemini model for natural language generation.

## Features

- 🌤️ Real-time weather data from Open-Meteo API
- 🤖 Natural language summaries using Google's Gemini AI
- 📍 Location-based weather reporting using coordinates
- 🚀 Fast, async API responses
- ✅ Input validation and error handling

## Prerequisites

- Python 3.7+
- Google Cloud API key with Gemini access
- Internet connection (for weather data fetching)

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd tds_AI_weather_report_summarizer
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Set up environment variables:
```bash
# Create .env file
echo "GOOGLE_API_KEY=your_api_key_here" > .env
```

## Running the Server

Start the server with:
```bash
python main.py
```

Or using uvicorn directly:
```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

## API Endpoints

### GET /
Root endpoint providing API information and available endpoints.

**Response:**
```json
{
    "message": "Weather Summary API",
    "version": "1.0.0",
    "endpoints": {
        "/weather-summary": "POST - Get weather summary for coordinates",
        "/health": "GET - Health check"
    }
}
```

### GET /health
Health check endpoint to verify service status.

**Response:**
```json
{
    "status": "healthy"
}
```

### POST /weather-summary
Get an AI-generated weather summary for specific coordinates.

**Request Body:**
```json
{
    "latitude": 37.7749,
    "longitude": -122.4194
}
```

**Response:**
```json
{
    "summary": "It's currently 65°F and partly cloudy in San Francisco..."
}
```

## Testing

The project includes a test script to verify all endpoints:

```bash
# Run all endpoint tests
./test_endpoints.sh

# Run tests without starting server
NO_START=1 ./test_endpoints.sh

# Test against a different base URL
BASE_URL=http://localhost:8000 ./test_endpoints.sh
```

## Error Handling

The API includes comprehensive error handling for:
- Invalid coordinates
- Weather data fetch failures
- AI service unavailability
- Missing API keys
- Invalid request formats

## Technologies Used

- FastAPI: Web framework
- Pydantic: Data validation
- Open-Meteo: Weather data
- Google Gemini: AI text generation
- Python-dotenv: Environment management

## License

[Your chosen license]

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.