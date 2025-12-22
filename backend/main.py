from fastapi import FastAPI, HTTPException, Request, Body
from fastapi.middleware.cors import CORSMiddleware
from minio import Minio
from pydantic import BaseModel
import os
import io

app = FastAPI(title="NingGuru Pro API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio:9000")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "ningguru")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "12345678")
BUCKET_NAME = "ningguru-files"
# 这里读到的还是 9000 的地址，下面我们会处理它
EXTERNAL_ENDPOINT = os.getenv("EXTERNAL_ENDPOINT", "")

client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=False
)

@app.on_event("startup")
def ensure_bucket():
    if not client.bucket_exists(BUCKET_NAME):
        client.make_bucket(BUCKET_NAME)

class FolderReq(BaseModel):
    path: str

class DeleteReq(BaseModel):
    paths: list[str]

# 🔥 核心修改：生成走 8080 端口代理的链接
def fix_url(url: str):
    if EXTERNAL_ENDPOINT:
        # EXTERNAL_ENDPOINT 格式通常是 "IP:9000"
        # 我们只取 IP 部分
        ip = EXTERNAL_ENDPOINT.split(":")[0]
        
        # 将 "minio:9000" 替换为 "IP:8080/minio-api"
        # 这样浏览器就会发请求给 Nginx，Nginx 再转给 MinIO
        if "minio:9000" in url:
            return url.replace("http://minio:9000", f"http://{ip}:8080/minio-api")
            
    return url

@app.post("/list")
def list_files(req: FolderReq):
    prefix = req.path
    if prefix and not prefix.endswith('/'): prefix += '/'
    if prefix == "/": prefix = ""
    try:
        objects = client.list_objects(BUCKET_NAME, prefix=prefix, recursive=False)
        files = []
        folders = []
        for obj in objects:
            if obj.is_dir:
                folders.append({"name": obj.object_name.replace(prefix, "").strip("/"), "path": obj.object_name})
            else:
                raw_url = client.get_presigned_url("GET", BUCKET_NAME, obj.object_name)
                files.append({
                    "name": obj.object_name.replace(prefix, ""),
                    "full_path": obj.object_name,
                    "size": round(obj.size / 1024 / 1024, 2),
                    "last_modified": obj.last_modified,
                    # 使用修复后的链接
                    "url": fix_url(raw_url), 
                    "type": "video" if obj.object_name.lower().endswith(('.mp4','.mp3')) else "doc"
                })
        return {"folders": folders, "files": files}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/create_folder")
def create_folder(req: FolderReq):
    path = req.path
    if not path.endswith('/'): path += '/'
    try:
        client.put_object(BUCKET_NAME, path, io.BytesIO(b""), 0)
        return {"status": "ok"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/get_upload_url")
def get_upload_url(data: dict = Body(...)):
    filename = data.get("filename")
    prefix = data.get("prefix", "")
    full_path = prefix + filename
    try:
        url = client.get_presigned_url("PUT", BUCKET_NAME, full_path)
        # 上传链接也必须修复
        return {"url": fix_url(url), "full_path": full_path}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/delete")
def delete_items(req: DeleteReq):
    try:
        for path in req.paths:
            if path.endswith('/'):
                objects = client.list_objects(BUCKET_NAME, prefix=path, recursive=True)
                for obj in objects:
                    client.remove_object(BUCKET_NAME, obj.object_name)
            else:
                client.remove_object(BUCKET_NAME, path)
        return {"status": "ok"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
