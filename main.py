from fastapi import FastAPI, HTTPException, Request, Form
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse, RedirectResponse
from datetime import datetime
from pydantic import BaseModel, Field, field_validator
import requests
from typing import Optional
import os
from dotenv import load_dotenv
import warnings

# Suppress Pydantic warning from google-genai compatibility
warnings.filterwarnings("ignore", message="Field name .* shadows an attribute in parent")

from google import genai

# Load environment variables from .env file
load_dotenv()

# Initialize Gemini client directly from environment
# This avoids storing the API key in an intermediate variable
try:
    if not os.getenv("GOOGLE_API_KEY"):
        raise ValueError("GOOGLE_API_KEY environment variable is not set")
    client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
    # Clear any loaded API key from error messages/traces
    os.environ["GOOGLE_API_KEY"] = "[FILTERED]"
except Exception as e:
    # Avoid logging the actual error which might contain the key
    raise RuntimeError("Failed to initialize Gemini client. Check your API key configuration.") from None

app = FastAPI(
    title="Weather Summary API",
    description="Fetch weather data and get AI-powered summaries",
    version="1.0.0"
)

# Initialize templates with custom filters
templates = Jinja2Templates(directory="templates")

# Add custom Jinja2 filters
def nl2br(text):
    return text.replace('\n', '<br>')

templates.env.filters['nl2br'] = nl2br

# Pydantic models for request/response validation
class WeatherRequest(BaseModel):
    latitude: float = Field(..., ge=-90, le=90, description="Latitude coordinate")
    longitude: float = Field(..., ge=-180, le=180, description="Longitude coordinate")
    
    @field_validator('latitude')
    def validate_latitude(cls, v):
        if not -90 <= v <= 90:
            raise ValueError('Latitude must be between -90 and 90')
        return v
    
    @field_validator('longitude')
    def validate_longitude(cls, v):
        if not -180 <= v <= 180:
            raise ValueError('Longitude must be between -180 and 180')
        return v


class WeatherSummary(BaseModel):
    summary: str


# Service functions
def fetch_weather_data(latitude: float, longitude: float) -> dict:
    """
    Fetch weather data from Open-Meteo API.
    
    Args:
        latitude: Latitude coordinate
        longitude: Longitude coordinate
        
    Returns:
        dict: Raw weather data from Open-Meteo API
        
    Raises:
        HTTPException: If the API request fails
    """
    url = "https://api.open-meteo.com/v1/forecast"
    
    params = {
        "latitude": latitude,
        "longitude": longitude,
        "current": "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m",
        "hourly": "temperature_2m,precipitation_probability,precipitation",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code",
        "timezone": "auto",
        "forecast_days": 3
    }
    
    try:
        response = requests.get(url, params=params, timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        raise HTTPException(
            status_code=503,
            detail=f"Failed to fetch weather data: {str(e)}"
        )


def get_llm_summary(weather_data: dict, latitude: float, longitude: float) -> str:
    """
    Send weather data to Gemini LLM for summarization.
    
    Args:
        weather_data: Raw weather data from Open-Meteo
        latitude: Latitude coordinate
        longitude: Longitude coordinate
        
    Returns:
        str: Human-readable weather summary
        
    Raises:
        HTTPException: If the Gemini API request fails
    """
    if not os.getenv("GOOGLE_API_KEY"):
        raise HTTPException(
            status_code=500,
            detail="Google API key not configured"
        )
    
    # Create a clear summarization prompt focused on natural language
    prompt = f"""You are a friendly weather assistant. Based on this weather data, give me a natural, conversational summary of the weather for coordinates ({latitude}, {longitude}). Include current conditions and a brief 3-day forecast. Focus on what it feels like and what people should expect. Keep it simple, clear and under 150 words.

Weather Data:
{weather_data}"""
    
    try:
        response = client.models.generate_content(
            model="gemini-2.5-pro",
            contents=prompt
        )
        if not response or not response.text:
            raise ValueError("Empty response from Gemini API")
        return response.text
    except Exception as e:
        # Log the actual error securely (you should add proper logging here)
        # but return a generic message to the client
        raise HTTPException(
            status_code=503,
            detail="Failed to generate weather summary. Please try again later."
        )


# API Endpoints
@app.get("/", response_class=HTMLResponse)
async def root(request: Request):
    """Serve the home page with weather summary form."""
    return templates.TemplateResponse(
        "home.html",
        {"request": request}
    )

@app.get("/api")
async def api_info():
    """API information endpoint."""
    return {
        "message": "Weather Summary API",
        "version": "1.0.0",
        "endpoints": {
            "/weather-summary": "POST - Get weather summary for coordinates",
            "/health": "GET - Health check"
        }
    }


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy"}


@app.post("/weather-summary")
async def get_weather_summary(
    request: Request,
    latitude: float = Form(...),
    longitude: float = Form(...)
):
    """
    Get AI-powered weather summary for given coordinates and render the summary template.
    
    Args:
        request: FastAPI request object
        latitude: Latitude coordinate from form
        longitude: Longitude coordinate from form
        
    Returns:
        TemplateResponse: Rendered summary template
    """
    try:
        # Validate coordinates
        if not -90 <= latitude <= 90:
            raise ValueError("Latitude must be between -90 and 90")
        if not -180 <= longitude <= 180:
            raise ValueError("Longitude must be between -180 and 180")

        # Fetch weather data from Open-Meteo
        weather_data = fetch_weather_data(latitude, longitude)
        
        # Get LLM summary
        summary = get_llm_summary(weather_data, latitude, longitude)
        
        # Render the summary template
        return templates.TemplateResponse(
            "summary.html",
            {
                "request": request,
                "summary": summary,
                "latitude": latitude,
                "longitude": longitude,
                "timestamp": datetime.utcnow()
            }
        )
    except ValueError as e:
        # Redirect back to home with error
        return RedirectResponse(
            url=f"/?error={str(e)}",
            status_code=303
        )
    except Exception as e:
        # Redirect back to home with error
        return RedirectResponse(
            url="/?error=Failed to generate weather summary. Please try again.",
            status_code=303
        )
    # Return just the summary
    return WeatherSummary(summary=summary)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)