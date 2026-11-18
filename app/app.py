
import os
from flask import Flask, request, jsonify, render_template_string
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

def get_connection():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5
    )

def initialize_database():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS courses (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(200) UNIQUE NOT NULL,
                    description TEXT NOT NULL
                )
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS enrollments (
                    id SERIAL PRIMARY KEY,
                    student_name VARCHAR(150) NOT NULL,
                    course_id INTEGER NOT NULL REFERENCES courses(id),
                    enrolled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            cur.execute("""
                INSERT INTO courses (title, description)
                VALUES
                  ('AWS Cloud Computing', 'Learn AWS EC2, VPC and S3'),
                  ('DevOps Engineering', 'Learn Docker, Jenkins and Kubernetes'),
                  ('Azure Administration', 'Learn Azure infrastructure')
                ON CONFLICT (title) DO NOTHING
            """)

@app.route("/")
def home():
    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT id, title, description FROM courses ORDER BY id")
            courses = cur.fetchall()

    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>
      <title>YBNP Kishore Learning Platform</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body {font-family:Arial,sans-serif;background:#f1f5f9;margin:0;color:#172033}
        header {background:#173b76;color:white;padding:35px;text-align:center}
        main {max-width:950px;margin:35px auto;padding:0 20px}
        .grid {display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:20px}
        .card {background:white;border-radius:12px;padding:24px;box-shadow:0 3px 14px #0001}
        button {background:#2563eb;color:white;border:0;padding:12px 18px;border-radius:7px;cursor:pointer}
        input {padding:12px;border:1px solid #ccc;border-radius:7px;width:90%;margin:10px 0}
        #message {margin-top:15px}
      </style>
    </head>
    <body>
      <header>
        <h1>Kishore Learning Platform</h1>
        <p>Cloud Computing | DevOps | Azure</p>
      </header>
      <main>
        <h2>Available Courses</h2>
        <div class="grid">
          {% for course in courses %}
          <div class="card">
            <h3>{{ course.title }}</h3>
            <p>{{ course.description }}</p>
            <input id="student-{{course.id}}" placeholder="Enter your name">
            <button onclick="enroll({{course.id}})">Enroll Now</button>
            <p id="message-{{course.id}}"></p>
          </div>
          {% endfor %}
        </div>
      </main>
      <script>
        async function enroll(courseId) {
          const name = document.getElementById('student-' + courseId).value;
          const message = document.getElementById('message-' + courseId);
          try {
            const response = await fetch('/api/enroll', {
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({student_name:name,course_id:courseId})
            });
            const result = await response.json();
            message.textContent = result.message || result.error;
          } catch (error) {
            message.textContent = 'Enrollment request failed';
          }
        }
      </script>
    </body>
    </html>
    """, courses=courses)

@app.route("/api/courses")
def list_courses():
    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT * FROM courses ORDER BY id")
            return jsonify(cur.fetchall())

@app.route("/api/enroll", methods=["POST"])
def enroll():
    data = request.get_json(silent=True) or {}
    name = str(data.get("student_name", "")).strip()
    course_id = data.get("course_id")

    if not name or len(name) > 150:
        return jsonify(error="Enter a valid student name"), 400

    try:
        course_id = int(course_id)
    except (TypeError, ValueError):
        return jsonify(error="Invalid course ID"), 400

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM courses WHERE id=%s", (course_id,))
            if not cur.fetchone():
                return jsonify(error="Course not found"), 404
            cur.execute(
                "INSERT INTO enrollments (student_name,course_id) VALUES (%s,%s)",
                (name, course_id)
            )

    return jsonify(message="Enrollment successful!"), 201

@app.route("/health")
def health():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return jsonify(status="healthy"), 200
    except psycopg2.Error:
        return jsonify(status="unhealthy"), 503

if __name__ == "__main__":
    initialize_database()
    app.run(host="0.0.0.0", port=5000)
