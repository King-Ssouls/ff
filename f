from flask import Flask, jsonify, request
import json
import time
from pathlib import Path
import redis

app = Flask(__name__)

memurai = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)

def check_memurai():
    try:
        if memurai.ping():
            print("Memurai подключен: PONG")
            return True
    except (redis.exceptions.ConnectionError,
            redis.exceptions.TimeoutError):
        print("Не удалось подключиться к Memurai по адресу 127.0.0.1:6379")
        return False
    return False

PRODUCT_FILE = Path(__file__).with_name("product.json")

def get_product_by_id(product_id):
    time.sleep(20)
    with PRODUCT_FILE.open(encoding="utf-8") as file:
        products = json.load(file)

    for product in products:
        if product["id"] == product_id:
            return product
    return None

def load_all_products():
    with PRODUCT_FILE.open(encoding="utf-8") as file:
        return json.load(file)

@app.route("/products", methods=["GET"])
def index():
    start_time = time.perf_counter()
    cache_key = "cache:products:all"
    cache_json = memurai.get(cache_key)

    if cache_json is not None:
        products = json.loads(cache_json)
        duration_ms = round((time.perf_counter() - start_time) * 1000, 3)

        response = jsonify({
            "source": "cache",
            "duration_ms": duration_ms,
            "data": products
        })
        response.headers["X-Cache"] = "HIT"
        return response

    products = load_all_products()

    memurai.setex(
        cache_key,
        20,
        json.dumps(products, ensure_ascii=False)
    )

    duration_ms = round((time.perf_counter() - start_time) * 1000, 3)

    response = jsonify({
        "source": "json",
        "duration_ms": duration_ms,
        "data": products
    })
    response.headers["X-Cache"] = "MISS"
    return response

@app.route("/products/<int:product_id>", methods=["GET"])
def get_product_route(product_id):
    start_time = time.perf_counter()
    cache_key = f"cache:product:{product_id}"

    cached_json = memurai.get(cache_key)

    if cached_json is not None:
        product = json.loads(cached_json)
        duration_ms = round((time.perf_counter() - start_time) * 1000, 3)

        response = jsonify({
            "source": "cache",
            "duration_ms": duration_ms,
            "data": product
        })
        response.headers["X-Cache"] = "HIT"
        return response

    product = get_product_by_id(product_id)

    if product is None:
        duration_ms = round((time.perf_counter() - start_time) * 1000, 3)
        response = jsonify({
            "source": "json",
            "duration_ms": duration_ms,
            "error": "Продукта нет"
        })
        response.headers["X-Cache"] = "MISS"
        return response, 404

    memurai.setex(cache_key, 30, json.dumps(product))

    duration_ms = round((time.perf_counter() - start_time) * 1000, 3)
    response = jsonify({
        "source": "json",
        "duration_ms": duration_ms,
        "data": product
    })
    response.headers["X-Cache"] = "MISS"
    return response

@app.route("/product/<int:product_id>", methods=["PUT"])
def update_product(product_id):
    data = request.get_json(silent=True)

    if not isinstance(data, dict):
        return jsonify({"error": "Тело не в формате JSON"}), 400

    name = data.get("name")
    price = data.get("price")

    if not name or not name.strip():
        return jsonify({"error": "Укажите название товара"}), 400

    with PRODUCT_FILE.open(encoding="utf-8") as file:
        products = json.load(file)

    found = False
    for product in products:
        if product["id"] == product_id:
            product["name"] = name
            product["price"] = price
            found = True
            break

    if not found:
        return jsonify({"error": "Товар не найден"}), 404

    PRODUCT_FILE.write_text(
        json.dumps(products, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    memurai.delete(f"cache:product:{product_id}")
    memurai.delete("cache:products:all")

    updated_product = next(p for p in products if p["id"] == product_id)
    return jsonify({
        "source": "json",
        "data": updated_product
    })

if __name__ == "__main__":
    check_memurai()
    app.run(debug=True)
