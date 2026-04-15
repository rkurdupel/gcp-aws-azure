from flask import Flask, jsonify, render_template, request, session, redirect
from flask_session import Session
import redis
import requests
import os

app = Flask(__name__)
# for signing session cookies
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY")  # is received from .env  file (ui.service.j2 (jinja2)) in ansible (incl vault)
app.config["SESSION_TYPE"] = "redis"
app.config["SESSION_PERMANENT"] = False
app.config["SESSION_REDIS"] = redis.Redis(
    host=os.environ.get("REDIS_HOST"),
    port = int(os.environ.get("REDIS_PORT")),
    password = os.environ.get("REDIS_PASSWORD"),
    decode_responses=False,
)
Session(app)

PROXY_HOST = os.environ.get("PROXY_HOST")
HISTORY_HOST = os.environ.get("HISTORY_HOST")
COINS = ("BTC", "ETH", "SOL", "BNB")

def get_current_price(coin="BTC"):
    try:
        response = requests.get(f"http://{PROXY_HOST}:5001/price/{coin}", timeout=5)
        return round(response.json()["price"], 2)
    except Exception as e:
        print(f"Proxy error: {e}")
        return None

def get_chart_data(coin="BTC", selected_date=None, selected_range="7D"):
    try:
        params = {"coin": coin, "range": selected_range}
        if selected_date:
            params["date"] = selected_date

        r = requests.get(f"http://{HISTORY_HOST}:5002/chart", params=params, timeout=5)
        return r.json()
    except Exception as e:
        print(f"Chart error: {e}")
        return {
            "coin": coin,
            "selected_date": selected_date,
            "range": selected_range,
            "highest_price": None,
            "lowest_price": None,
            "current_price": None,
            "points": [],
        }

@app.route("/")
def index():
    # request.args = ?... (localhost:5000?coin=ETH)
    # get coin from query paramter, if not provided - set default to BTC and make it uppercase
    # when user enters / for the first time - coin is not provided - default to BTC, when user clicks on ETH - coin=ETH, when user clicks on SOL - coin=SOL
    coin = request.args.get("coin")
    if not coin:
        coin = session.get("selected_coin", "BTC")
    selected_range = request.args.get("range")
    if not selected_range:
        selected_range = session.get("selected_range", "7D")

    # if coin is not in the list of supported coins - set it to default BTC
    if coin not in COINS:
        coin = "BTC"    
    if selected_range not in {"1H", "24H", "7D", "1M"}:
        selected_range = "7D"

    session["selected_coin"] = coin
    session["selected_range"] = selected_range

    live_price = get_current_price(coin)
    chart_data = get_chart_data(coin, None, selected_range)
    current_price = live_price if live_price is not None else chart_data.get("current_price")
    highest_price = chart_data.get("highest_price")
    lowest_price = chart_data.get("lowest_price")

    return render_template("index.html", 
    current_price=current_price,
    selected_coin=coin,
    coins=COINS,
    highest_price=highest_price,
    lowest_price=lowest_price,
    selected_range=selected_range
)


@app.route("/history")
def history():

    if request.args.get("reset") == "1":
        session.pop("history_coin", None)
        session.pop("history_date", None)
        session.pop("history_sort", None)
        session.pop("history_limit", None)
        return redirect("/history")


    coin = request.args.get("coin")
    if coin is None:
        coin = session.get("history_coin", "")

    selected_date = request.args.get("date")
    if selected_date is None:
        selected_date = session.get("history_date", "")

    sort_value = request.args.get("sort")
    if not sort_value:
        sort_value = session.get("history_sort", "newest")

    limit_value = request.args.get("limit")
    if not limit_value:
        limit_value = session.get("history_limit", "50")
   

    if coin and coin not in COINS:
        coin = ""
    if sort_value not in {"newest", "oldest", "highest", "lowest"}:
        sort_value = "newest"
    if limit_value not in {"25", "50", "100", "250"}:
        limit_value = "50"

        
    session["history_coin"] = coin
    session["history_date"] = selected_date
    session["history_sort"] = sort_value
    session["history_limit"] = limit_value



    try:
        params = {
            "sort": sort_value,
            "limit": limit_value,
        }
        if coin:
            params["coin"] = coin
        if selected_date:
            params["date"] = selected_date

        r = requests.get(f"http://{HISTORY_HOST}:5002/history", params=params, timeout=5)
        data = r.json()["data"]
    except Exception as e:
        print(f"History error: {e}")
        data = []
        
    return render_template(
        "history.html",
        data=data,
        coins=COINS,
        selected_coin=coin,
        selected_date=selected_date,
        selected_sort=sort_value,
        selected_limit=limit_value,
    )

    


@app.route("/api/chart-data")
def chart_data():
    coin = request.args.get("coin", "BTC").upper()
    if coin not in COINS:
        coin = "BTC"

    selected_range = request.args.get("range", "7D").upper()

    return jsonify(get_chart_data(coin, None, selected_range))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)  # 0 0 0 0 - ALL NETWORK INTERFACES LISTENING
