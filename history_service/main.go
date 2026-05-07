package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings" // every lib should be used in the code, otherwise it will be error
	"time"

	"github.com/streadway/amqp" // to work with rabbitmq

	_ "github.com/lib/pq"
)

var db *sql.DB
var postgres_table string

type Price struct {
	Coin       string  `json:"coin"`
	Price      float64 `json:"price"`
	RecordedAt string  `json:"recorded_at"` //`

}

func connectDB() *sql.DB {
	host := getEnv("POSTGRES_HOST", "")
	dbname := getEnv("POSTGRES_DB", "")
	user := getEnv("POSTGRES_USER", "")
	password := getEnv("POSTGRES_PASSWORD", "")

	connStr := fmt.Sprintf(
		"host=%s dbname=%s user=%s password=%s sslmode=disable",
		host, dbname, user, password,
	) // set value without printing

	db, err := sql.Open("postgres", connStr) // if not db set value as error
	if err != nil {                          // if error is present
		log.Fatalf("DB connection error: %v", err)
	}

	query := fmt.Sprintf(`
		CREATE TABLE IF NOT EXISTS %s (
			id SERIAL PRIMARY KEY,
			coin	VARCHAR(10) NOT NULL,
			price NUMERIC(15, 2) NOT NULL,
			recorded_at TIMESTAMP DEFAULT NOW()
		)`, postgres_table)

	_, err = db.Exec(query)

	if err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}

	log.Println("DB connected, table ready")

	return db
}

func saveToDB(coin string, price float64) error {
	var exists bool
	query := fmt.Sprintf(
		`SELECT EXISTS (
			SELECT 1
			FROM %s
			WHERE coin = $1
			  AND price = $2
			  AND recorded_at >= NOW() - INTERVAL '10 seconds'
		)`, postgres_table)
	err := db.QueryRow(query, coin, price).Scan(&exists)
	if err != nil {
		return fmt.Errorf("DB duplicate check error: %w", err)
	}
	if exists {
		log.Printf("Skipped duplicate DB insert: %s = %f", coin, price)
		return nil

	}

	// _, err = db.Exec(
	// 	"INSERT INTO currency_rates (coin, price) VALUES ($1, $2)", coin, price,
	// ) // we only need err, _ - omits the result of exec
	// // $1 placeholder for coin value, $2 for price value
	query = fmt.Sprintf("INSERT INTO %s (coin, price) VALUES ($1, $2)", postgres_table)
	_, err = db.Exec(query, coin, price)

	if err != nil {
		return fmt.Errorf("DB insert error: %w", err)
	}
	log.Printf("Saved to DB: %s = %f", coin, price)
	return nil
}

func startWorker() {
	host := getEnv("RABBITMQ_HOST", "")
	user := getEnv("RABBITMQ_USER", "")
	password := getEnv("RABBITMQ_PASS", "")
	queue := getEnv("RABBITMQ_QUEUE", "")

	for {
		url := fmt.Sprintf("amqp://%s:%s@%s:5672/", user, password, host)
		conn, err := amqp.Dial(url) // connect to rabbitmq server
		if err != nil {
			log.Printf("RabbitMQ error: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		ch, err := conn.Channel()
		if err != nil {
			log.Printf("Channel error: %v", err)
			conn.Close()
			time.Sleep(5 * time.Second)
			continue
		}

		q, err := ch.QueueDeclare(queue, true, false, false, false, nil)
		if err != nil {
			log.Printf("Queue error: %v", err)
			continue
		}
		// nil = None
		// consume msgs from the queue (queue, tag, auto-acknowledge, exclusive, nolocal, notwait, args)
		msgs, err := ch.Consume(q.Name, "", false, false, false, false, nil)
		if err != nil {
			log.Printf("Consume error: %v", err)
			continue
		}

		log.Println("Worker started")

		for msg := range msgs {
			var data map[string]interface{} // {"key": 54.45}
			// unmarshal json -> map(dict) (json.loads())
			// 1) asign value to err 2) check err != nil
			if err := json.Unmarshal(msg.Body, &data); err != nil {
				log.Printf("JSON error: %v", err)
				// multiple, requeue
				// error occured - do not acknowledge msg - return it to queue
				msg.Nack(false, false)
				continue // skip the lower code and move to the next msg
			}
			price := data["price"].(float64)
			coin, ok := data["coin"].(string) // if not coin - then data=ok
			if !ok || coin == "" {            // if not ok or coin is empty
				coin = "BTC"
			}
			log.Printf("Received: %s = %f", coin, price)

			if err := saveToDB(coin, price); err != nil {
				log.Printf("Save failed: %v", err)
				// error occured - do not acknowledge msg - return it to queue
				msg.Nack(false, true)
				continue
			}

			msg.Ack(false) // acknowledge that msg is processed successfully (false - only this msg (single acknowledgment))
		}

		conn.Close()
		time.Sleep(5 * time.Second)
	}
}

func historyHandler(w http.ResponseWriter, r *http.Request) {
	coin := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("coin")))
	selectedDate := strings.TrimSpace(r.URL.Query().Get("date"))
	sortValue := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("sort")))
	limitValue := strings.TrimSpace(r.URL.Query().Get("limit"))

	whereParts := []string{}
	args := []interface{}{}
	argIndex := 1

	if coin != "" {
		whereParts = append(whereParts, fmt.Sprintf("coin = $%d", argIndex))
		args = append(args, coin)
		argIndex++
	}

	if selectedDate != "" {
		parsedDate, err := time.ParseInLocation("2006-01-02", selectedDate, time.Local)
		if err != nil {
			http.Error(w, "invalid date", http.StatusBadRequest)
			return
		}

		startOfDay := time.Date(parsedDate.Year(), parsedDate.Month(), parsedDate.Day(), 0, 0, 0, 0, time.Local)
		endOfDay := startOfDay.Add(24 * time.Hour)

		whereParts = append(whereParts, fmt.Sprintf("recorded_at >= $%d", argIndex))
		args = append(args, startOfDay)
		argIndex++

		whereParts = append(whereParts, fmt.Sprintf("recorded_at < $%d", argIndex))
		args = append(args, endOfDay)
		argIndex++
	}

	query := fmt.Sprintf("SELECT coin, price, recorded_at FROM %s", postgres_table)
	if len(whereParts) > 0 {
		query += " WHERE " + strings.Join(whereParts, " AND ")
	}

	switch sortValue {
	case "oldest":
		query += " ORDER BY recorded_at ASC"
	case "highest":
		query += " ORDER BY price DESC, recorded_at DESC"
	case "lowest":
		query += " ORDER BY price ASC, recorded_at DESC"
	default:
		sortValue = "newest"
		query += " ORDER BY recorded_at DESC"
	}

	limit := 50
	if limitValue != "" {
		parsedLimit, err := strconv.Atoi(limitValue)
		if err == nil {
			switch parsedLimit {
			case 25, 50, 100, 250:
				limit = parsedLimit
			}
		}
	}

	query += fmt.Sprintf(" LIMIT $%d", argIndex)
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		http.Error(w, "DB error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	// SHOW VALUES FROM DB IN JSON FORMAT 5002
	var prices []Price
	for rows.Next() { // iterate through sql data request rows
		var p Price
		var t time.Time // type of time
		if err := rows.Scan(&p.Coin, &p.Price, &t); err != nil {
			continue
		}
		p.RecordedAt = t.Format("2006-01-02 15:04:05")
		prices = append(prices, p)
	}

	if prices == nil {
		prices = []Price{}
	}
	w.Header().Set("Content-Type", "application/json") // set header to json
	// map - {} string key type interface any type {'key': value}
	// convert data from json to map and send to client
	json.NewEncoder(w).Encode(map[string]interface{}{
		"data": prices,
	})
}

// stats (highest, lowest) value
type Stats struct {
	Highest_Price float64 `json:"highest_price"`
	Lowest_Price  float64 `json:"lowest_price"`
}

type ChartPoint struct {
	Price      float64 `json:"price"`
	RecordedAt string  `json:"recorded_at"`
	Label      string  `json:"label"`
}

type ChartResponse struct {
	Coin         string       `json:"coin"`
	SelectedDate string       `json:"selected_date"`
	Range        string       `json:"range"`
	HighestPrice float64      `json:"highest_price"`
	LowestPrice  float64      `json:"lowest_price"`
	CurrentPrice *float64     `json:"current_price"`
	Points       []ChartPoint `json:"points"`
}

type RawChartPoint struct {
	Price      float64
	RecordedAt time.Time
}

func statsHandler(w http.ResponseWriter, r *http.Request) {
	// get coin from query params default - BTC
	coin := strings.ToUpper(r.URL.Query().Get("coin"))
	if coin == "" {
		coin = "BTC"
	}

	var stats Stats
	query := fmt.Sprintf(
		"SELECT MAX(price), MIN(price) FROM %s WHERE coin = $1",
		postgres_table,
	)
	err := db.QueryRow(query, coin).Scan(&stats.Highest_Price, &stats.Lowest_Price)

	if err != nil {
		http.Error(w, "DB error", http.StatusInternalServerError)
		return
	}

	// return data to client in json format
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

func parseRangeWindow(rangeValue string) (time.Duration, string) {
	switch strings.ToUpper(rangeValue) {
	case "1H":
		return time.Hour, "15:04"
	case "24H":
		return 24 * time.Hour, "02 Jan 15:04"
	case "1M":
		return 30 * 24 * time.Hour, "02 Jan"
	default:
		return 7 * 24 * time.Hour, "02 Jan 15:04"
	}
}

func pointStrideForRange(rangeValue string) int {
	switch strings.ToUpper(rangeValue) {
	case "24H":
		return 24
	case "7D":
		return 48
	case "1M":
		return 192
	default:
		return 1
	}
}

func bucketDurationForRange(rangeValue string) time.Duration {
	switch strings.ToUpper(rangeValue) {
	case "1H":
		return 15 * time.Minute
	case "24H":
		return time.Hour
	default:
		return 0
	}
}

func roundDownTime(t time.Time, step time.Duration) time.Time {
	if step <= 0 {
		return t
	}
	return t.Truncate(step)
}

func buildDisplayPoints(rawPoints []RawChartPoint, rangeValue string, labelFormat string) []ChartPoint {
	bucketDuration := bucketDurationForRange(rangeValue)
	if bucketDuration <= 0 {
		points := make([]ChartPoint, 0, len(rawPoints))
		for _, rawPoint := range rawPoints {
			points = append(points, ChartPoint{
				Price:      rawPoint.Price,
				RecordedAt: rawPoint.RecordedAt.Format("2006-01-02 15:04:05"),
				Label:      rawPoint.RecordedAt.Format(labelFormat),
			})
		}
		return downsamplePoints(points, pointStrideForRange(rangeValue))
	}

	buckets := make(map[time.Time]ChartPoint)
	order := []time.Time{}

	for _, rawPoint := range rawPoints {
		bucketStart := roundDownTime(rawPoint.RecordedAt, bucketDuration)
		if _, exists := buckets[bucketStart]; !exists {
			order = append(order, bucketStart)
		}

		buckets[bucketStart] = ChartPoint{
			Price:      rawPoint.Price,
			RecordedAt: rawPoint.RecordedAt.Format("2006-01-02 15:04:05"),
			Label:      bucketStart.Format(labelFormat),
		}
	}

	points := make([]ChartPoint, 0, len(order))
	for _, bucketStart := range order {
		points = append(points, buckets[bucketStart])
	}

	return points
}

func downsamplePoints(points []ChartPoint, stride int) []ChartPoint {
	if stride <= 1 || len(points) <= 2 {
		return points
	}

	reduced := make([]ChartPoint, 0, (len(points)/stride)+2)
	for index, point := range points {
		if index == 0 || index == len(points)-1 || index%stride == 0 {
			reduced = append(reduced, point)
		}
	}

	return reduced
}

func parseSelectedDate(dateValue string) (time.Time, error) {
	if strings.TrimSpace(dateValue) == "" {
		now := time.Now()
		return now.Truncate(time.Minute), nil
	}

	layouts := []string{"2006-01-02T15:04", "2006-01-02 15:04", "2006-01-02"}
	for _, layout := range layouts {
		parsed, err := time.ParseInLocation(layout, dateValue, time.Local)
		if err == nil {
			if layout == "2006-01-02" {
				return time.Date(parsed.Year(), parsed.Month(), parsed.Day(), 23, 59, 0, 0, time.Local), nil
			}
			return parsed, nil
		}
	}

	return time.Time{}, fmt.Errorf("invalid date")
}

func latestRecordedAtForCoin(coin string) (time.Time, error) {
	var recordedAt time.Time
	// - if there are no rows for that coin, MAX(recorded_at) becomes NULL
	//- COALESCE(..., NOW()) replaces that NULL with the current timestamp
	query := fmt.Sprintf(
		"SELECT COALESCE(MAX(recorded_at), NOW()) FROM %s WHERE coin = $1",
		postgres_table,
	)
	err := db.QueryRow(query, coin).Scan(&recordedAt)
	return recordedAt, err
}

func chartHandler(w http.ResponseWriter, r *http.Request) {
	coin := strings.ToUpper(r.URL.Query().Get("coin"))
	if coin == "" {
		coin = "BTC"
	}

	var (
		selectedDate time.Time
		err          error
	)

	dateValue := r.URL.Query().Get("date")
	if strings.TrimSpace(dateValue) == "" {
		selectedDate, err = latestRecordedAtForCoin(coin)
	} else {
		selectedDate, err = parseSelectedDate(dateValue)
	}
	if err != nil {
		http.Error(w, "invalid date", http.StatusBadRequest)
		return
	}

	rangeValue := strings.ToUpper(r.URL.Query().Get("range"))
	if rangeValue == "" {
		rangeValue = "7D"
	}

	window, labelFormat := parseRangeWindow(rangeValue)
	startTime := selectedDate.Add(-window)

	rows, err := db.Query(
		`SELECT price, recorded_at
		 FROM currency_rates
		 WHERE coin = $1 AND recorded_at BETWEEN $2 AND $3
		 ORDER BY recorded_at ASC`,
		coin, startTime, selectedDate,
	)
	if err != nil {
		http.Error(w, "DB error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	response := ChartResponse{
		Coin:         coin,
		SelectedDate: selectedDate.Format("2006-01-02T15:04"),
		Range:        rangeValue,
		Points:       []ChartPoint{},
	}
	rawPoints := []RawChartPoint{}

	var highestSet bool
	for rows.Next() {
		var recordedAt time.Time
		var price float64
		if err := rows.Scan(&price, &recordedAt); err != nil {
			continue
		}

		rawPoints = append(rawPoints, RawChartPoint{
			Price:      price,
			RecordedAt: recordedAt,
		})

		if !highestSet || price > response.HighestPrice {
			response.HighestPrice = price
		}
		if !highestSet || price < response.LowestPrice {
			response.LowestPrice = price
		}
		current := price
		response.CurrentPrice = &current
		highestSet = true
	}

	response.Points = buildDisplayPoints(rawPoints, rangeValue, labelFormat)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func main() {
	postgres_table = getEnv("POSTGRES_TABLE", "")

	db = connectDB()
	defer db.Close() // will be completed after all commands in the end

	go startWorker()

	http.HandleFunc("/history", historyHandler)
	log.Println("History service is running on port 5002")
	// activate stats handler for /stats endpoint
	http.HandleFunc("/stats", statsHandler)
	http.HandleFunc("/chart", chartHandler)
	// after listenandserver no rows will be executed
	log.Fatal(http.ListenAndServe("0.0.0.0:5002", nil))

}
