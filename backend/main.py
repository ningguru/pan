import os
import boto3
import uuid
import uvicorn
import datetime
from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List
from datetime import timedelta

# --- 数据库引用 ---
from sqlalchemy import create_engine, Column, String, DateTime
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session

app = FastAPI()

# ================= 1. 数据库持久化 =================
# 数据库文件，用于存 Token 和密码配置
SQLALCHEMY_DATABASE_URL = "sqlite:///./ningguru.db"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class ConfigDB(Base):
    __tablename__ = "configs"
    key = Column(String, primary_key=True, index=True)
    value = Column(String)

class TokenDB(Base):
    __tablename__ = "tokens"
    token = Column(String, primary_key=True, index=True)
    auth_type = Column(String) # 'global' 或 'private'
    expires_at = Column(DateTime)

Base.metadata.create_all(bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ================= 2. 基础配置 =================
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio:9000")
EXTERNAL_HOST = "pan.ningguru.cc.cd" 
ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "ningguru")
SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "12345678")
BUCKET_NAME = "drive"

# 默认密码 (优先读数据库)
ENV_SITE_PASSWORD = os.getenv("SITE_PASSWORD", "admin")
ENV_PRIVATE_PASSWORD = os.getenv("PRIVATE_PASSWORD", "private")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

s3 = boto3.client('s3',
    endpoint_url=f"http://{MINIO_ENDPOINT}",
    aws_access_key_id=ACCESS_KEY,
    aws_secret_access_key=SECRET_KEY,
    config=boto3.session.Config(signature_version='s3v4')
)

# 初始化 Bucket
try:
    s3.head_bucket(Bucket=BUCKET_NAME)
except:
    try:
        s3.create_bucket(Bucket=BUCKET_NAME)
        import json
        policy = {
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow", "Principal": {"AWS": ["*"]}, "Action": ["s3:GetObject"], "Resource": [f"arn:aws:s3:::{BUCKET_NAME}/*"]}]
        }
        s3.put_bucket_policy(Bucket=BUCKET_NAME, Policy=json.dumps(policy))
    except:
        pass

# ================= 3. 核心鉴权逻辑 =================

@app.on_event("startup")
def startup_event():
    """启动时初始化密码到数据库，防止重启丢失"""
    db = SessionLocal()
    if not db.query(ConfigDB).filter(ConfigDB.key == "site_password").first():
        db.add(ConfigDB(key="site_password", value=ENV_SITE_PASSWORD))
    if not db.query(ConfigDB).filter(ConfigDB.key == "private_password").first():
        db.add(ConfigDB(key="private_password", value=ENV_PRIVATE_PASSWORD))
    db.commit()
    db.close()

def verify_token(x_token: str = Header(None), db: Session = Depends(get_db)):
    """验证 Token 是否有效且未过期"""
    if not x_token:
        raise HTTPException(status_code=401, detail="请登录")
    
    record = db.query(TokenDB).filter(TokenDB.token == x_token).first()
    if not record:
        raise HTTPException(status_code=401, detail="登录失效，请重新登录")
    
    if record.expires_at < datetime.datetime.now():
        db.delete(record)
        db.commit()
        raise HTTPException(status_code=401, detail="登录已过期")
        
    return record.auth_type

# 模型
class LoginModel(BaseModel):
    password: str

class PathModel(BaseModel):
    path: str = ""
    is_private: bool = False

class FileModel(BaseModel):
    filename: str
    prefix: str = ""
    is_private: bool = False

class DeleteModel(BaseModel):
    paths: List[str]
    is_private: bool = False

def fix_url(url):
    if not url: return ""
    return url.replace(f"http://{MINIO_ENDPOINT}", f"http://{EXTERNAL_HOST}")

def get_real_prefix(user_path: str, is_private: bool):
    base = ".private/" if is_private else "public/"
    return base + user_path.lstrip("/")

# ================= 4. 接口实现 =================

@app.post("/login")
def login(data: LoginModel, db: Session = Depends(get_db)):
    """【主页登录】只允许公开密码"""
    db_site = db.query(ConfigDB).filter(ConfigDB.key == "site_password").first()
    db_priv = db.query(ConfigDB).filter(ConfigDB.key == "private_password").first()
    
    pwd_site = db_site.value if db_site else ENV_SITE_PASSWORD
    pwd_priv = db_priv.value if db_priv else ENV_PRIVATE_PASSWORD

    # 逻辑修正：严格区分
    if data.password == pwd_site:
        # 密码正确，生成30天有效 Token
        new_token = str(uuid.uuid4())
        expires = datetime.datetime.now() + timedelta(days=30)
        db.add(TokenDB(token=new_token, auth_type="global", expires_at=expires))
        db.commit()
        return {"token": new_token, "type": "global"}
    
    elif data.password == pwd_priv:
        # 如果用户在这里输了隐私密码，报错并提示
        raise HTTPException(status_code=400, detail="这是隐私密码，请点击右上角'隐私空间'登录")
    
    else:
        raise HTTPException(status_code=400, detail="密码错误")

@app.post("/login_private")
def login_private(data: LoginModel, db: Session = Depends(get_db)):
    """【隐私登录】只允许隐私密码"""
    db_priv = db.query(ConfigDB).filter(ConfigDB.key == "private_password").first()
    pwd_priv = db_priv.value if db_priv else ENV_PRIVATE_PASSWORD

    if data.password == pwd_priv:
        new_token = str(uuid.uuid4())
        expires = datetime.datetime.now() + timedelta(days=30)
        db.add(TokenDB(token=new_token, auth_type="private", expires_at=expires))
        db.commit()
        return {"token": new_token, "type": "private"}
    else:
        raise HTTPException(status_code=400, detail="隐私密码错误")

@app.post("/list")
def list_files(data: PathModel, auth_level: str = Depends(verify_token)):
    # 权限检查：如果是查隐私目录，必须是 private 级别
    if data.is_private and auth_level != "private":
        raise HTTPException(status_code=403, detail="权限不足")

    real_prefix = get_real_prefix(data.path, data.is_private)
    try:
        response = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=real_prefix, Delimiter='/')
    except:
        return {"folders": [], "files": []}

    folders = []
    if 'CommonPrefixes' in response:
        for p in response['CommonPrefixes']:
            full_p = p['Prefix']
            name = full_p[len(real_prefix):].rstrip('/')
            folders.append({"name": name, "path": data.path + name})

    files = []
    if 'Contents' in response:
        for obj in response['Contents']:
            key = obj['Key']
            if key == real_prefix: continue
            name = key[len(real_prefix):]
            size = round(obj['Size'] / 1024 / 1024, 2)
            lm = obj['LastModified'] + timedelta(hours=8)
            
            if data.is_private:
                raw = s3.generate_presigned_url('get_object', Params={'Bucket': BUCKET_NAME, 'Key': key}, ExpiresIn=3600)
                url = fix_url(raw) 
            else:
                url = f"http://{EXTERNAL_HOST}/{BUCKET_NAME}/{key}"

            ext = name.split('.')[-1].lower() if '.' in name else ''
            f_type = 'image' if ext in ['jpg','jpeg','png','gif'] else 'video' if ext in ['mp4','mov','avi'] else 'file'

            files.append({
                "name": name, "size": str(size), 
                "last_modified": lm.strftime("%Y-%m-%d %H:%M"), 
                "url": url, "type": f_type, "full_path": data.path + name
            })

    return {"folders": folders, "files": files}

@app.post("/get_upload_url")
def get_upload_url(data: FileModel, auth_level: str = Depends(verify_token)):
    if data.is_private and auth_level != "private":
        raise HTTPException(status_code=403, detail="权限")
    
    key = get_real_prefix(data.prefix, data.is_private) + data.filename
    raw = s3.generate_presigned_url(ClientMethod='put_object', Params={'Bucket': BUCKET_NAME, 'Key': key}, ExpiresIn=3600)
    return {"url": fix_url(raw)}

@app.post("/create_folder")
def create_folder(data: PathModel, auth_level: str = Depends(verify_token)):
    if data.is_private and auth_level != "private":
        raise HTTPException(status_code=403, detail="权限")
    p = get_real_prefix(data.path, data.is_private)
    if not p.endswith('/'): p += '/'
    s3.put_object(Bucket=BUCKET_NAME, Key=p)
    return {"status": "ok"}

@app.post("/delete")
def delete_files(data: DeleteModel, auth_level: str = Depends(verify_token)):
    if data.is_private and auth_level != "private":
        raise HTTPException(status_code=403, detail="权限")
    
    to_del = []
    for path in data.paths:
        p = get_real_prefix(path, data.is_private)
        items = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=p)
        if 'Contents' in items:
            for i in items['Contents']:
                to_del.append({'Key': i['Key']})
    
    if to_del:
        s3.delete_objects(Bucket=BUCKET_NAME, Delete={'Objects': to_del})
    return {"status": "ok"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
