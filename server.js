#!/usr/bin/env node

process.env.NODE_PATH = require('child_process')
    .execSync('npm root -g')
    .toString().trim();

require('module').Module._initPaths(); // 刷新 module 查找路径

const express = require('express');
const fs = require('fs');
const path = require('path');
const mm = require('music-metadata');
const multer = require('multer');

const app = express();
const PORT = 3000;

const DATA_FILE = 'music-map.json';
const SONG_DIR = __dirname;

app.use(express.json());
app.use(express.urlencoded({extended: true}));
app.use('/songs', express.static(SONG_DIR)); // 静态访问歌曲

// 文件上传配置
const upload = multer({dest: SONG_DIR});

// ------------------- 数据操作 -------------------
function initData() {
    if (!fs.existsSync(DATA_FILE)) {
        fs.writeFileSync(DATA_FILE, JSON.stringify({}, null, 2));
    }
    let data;
    try {
        data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8'));
    } catch (e) {
        console.error('数据文件格式错误，已初始化');
        data = {};
    }

    // 扫描当前目录 mp3 文件
    const files = fs.readdirSync(__dirname).filter(f => f.endsWith('.mp3'));


    // 课程音频文件格式: 20170221-2.mp3 20170316.mp3   20170411.mp3   20170504.mp3
    // 音乐格式：20170224-A.mp3 20170224-B.mp3
    files.forEach(file => {
        // 简单匹配课程文件名：8位数字开头 + 可选 -x
        if (/^\d{8}(-\d)?\.mp3$/.test(file)) {
            if (!data[file]) {
                data[file] = [null, null]; // 初始化两首歌为空
            }
        }
    });

    saveData(data);
}

function loadData() {
    initData();
    return JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8'))
}

function saveData(data) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
}

initData();

// ------------------- API -------------------

// 获取所有课程+歌曲
app.get('/api/list', (req, res) => {
    const data = loadData();
    res.json(data);
});

// 添加课程
app.post('/api/add-course', (req, res) => {
    const {course} = req.body;
    const data = loadData();
    if (!data[course]) {
        data[course] = [null, null]; // 默认两个空位
        saveData(data);
        res.json({message: `课程已添加: ${course}`});
    } else {
        res.json({message: `课程已存在: ${course}`});
    }
});

// 上传歌曲并分配到课程空位
app.post('/api/add-song', upload.single('song'), async (req, res) => {
    const {course} = req.body;
    const file = req.file;
    if (!file) return res.status(400).json({error: '没有上传文件'});

    const data = loadData();
    if (!data[course]) return res.status(400).json({error: '课程不存在'});

    // 找到第一个空位
    const index = data[course].indexOf(null);
    if (index === -1) return res.status(400).json({error: '该课程歌曲位置已满'});

    // 解析歌曲信息
    let metadata = {};
    try {
        const info = await mm.parseFile(file.path);
        metadata = {
            title: info.common.title || file.originalname,
            artist: info.common.artist || '未知',
            year: info.common.year || '未知'
        };
    } catch {
        metadata = {title: file.originalname, artist: '未知', year: '未知'};
    }

    // 生成新文件名
    const ext = path.extname(file.originalname);
    const newName = `${course.replace('.mp3', '')}-${String.fromCharCode(65 + index)}${ext}`;
    const newPath = path.join(SONG_DIR, newName);
    fs.renameSync(file.path, newPath);

    // 保存映射
    data[course][index] = newName;
    saveData(data);

    res.json({message: `歌曲已添加到课程 ${course}`, file: newName, metadata});
});

// 删除歌曲（保持空位）
app.post('/api/remove-song', (req, res) => {
    const {course, slot} = req.body; // slot: 0 或 1
    const data = loadData();
    if (!data[course]) return res.status(400).json({error: '课程不存在'});

    const songName = data[course][slot];
    if (!songName) return res.status(400).json({error: '该位置为空'});

    const filePath = path.join(SONG_DIR, songName);
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);

    data[course][slot] = null;
    saveData(data);
    res.json({message: `已删除 ${songName}`});
});

// ------------------- HTML 页面 -------------------
app.get('/', (req, res) => {
    const data = loadData();
    let html = `
  <!DOCTYPE html>
  <html>
  <head>
    <meta charset="utf-8">
    <title>课程与歌曲管理</title>
  </head>
  <body>
    <h2>课程列表</h2>
    <ul>
  `;

    for (const [course, songs] of Object.entries(data)) {
        html += `<li>${course}<ul>`;
        songs.forEach((s, i) => {
            if (s) {
                html += `<li>${s} <a href="/songs/${s}" target="_blank">播放</a></li>`;
            } else {
                html += `<li>空位 ${i + 1}</li>`;
            }
        });
        html += `</ul></li>`;
    }

    html += `</ul></body></html>`;
    res.send(html);
});

// ------------------- 启动 -------------------
app.listen(PORT, () => {
    console.log(`Server running at http://localhost:${PORT}`);
});
