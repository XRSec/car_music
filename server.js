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
    // 音乐格式：使用数字序号以确保播放器正确排序：001-课程.mp3, 002-歌曲1.mp3, 003-歌曲2.mp3
    files.forEach(file => {
        // 匹配课程文件名：8位数字开头 + 可选 -数字
        if (/^\d{8}(-\d+)?\.mp3$/.test(file)) {
            if (!data[file]) {
                data[file] = {
                    songs: [null, null], // 两首歌曲位置
                    metadata: null,      // 课程元数据
                    renamed_files: []    // 重命名后的文件列表
                };
            } else if (Array.isArray(data[file])) {
                // 兼容旧数据格式：[song1, song2] -> {songs: [song1, song2], ...}
                const oldSongs = data[file];
                data[file] = {
                    songs: oldSongs,
                    metadata: null,
                    renamed_files: []
                };
            }
        }
    });

    saveData(data);
}

function loadData() {
    initData();
    return JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8'));
}

function saveData(data) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
}

// 获取音乐元数据
async function getMusicMetadata(filePath) {
    try {
        const metadata = await mm.parseFile(filePath);
        return {
            title: metadata.common.title || path.basename(filePath, '.mp3'),
            artist: metadata.common.artist || '未知艺术家',
            album: metadata.common.album || '未知专辑',
            year: metadata.common.year || '未知年份',
            genre: metadata.common.genre ? metadata.common.genre.join(', ') : '未知流派',
            duration: metadata.format.duration ? Math.round(metadata.format.duration) : 0
        };
    } catch (error) {
        return {
            title: path.basename(filePath, '.mp3'),
            artist: '未知艺术家',
            album: '未知专辑', 
            year: '未知年份',
            genre: '未知流派',
            duration: 0
        };
    }
}

// 生成播放器友好的文件名（数字序号）
function generatePlaylistName(courseFile, songIndex, totalCourses) {
    const courseMatch = courseFile.match(/(\d{8})(-\d+)?/);
    if (!courseMatch) return null;
    
    const dateStr = courseMatch[1];
    const courseNum = courseMatch[2] ? courseMatch[2].substring(1) : '1';
    
    // 计算在所有课程中的位置
    const coursePosition = Object.keys(loadData()).sort().indexOf(courseFile) + 1;
    
    // 课程文件：001, 004, 007...
    // 歌曲文件：002, 003, 005, 006, 008, 009...
    const courseSeq = String(coursePosition * 3 - 2).padStart(3, '0');
    const song1Seq = String(coursePosition * 3 - 1).padStart(3, '0');
    const song2Seq = String(coursePosition * 3).padStart(3, '0');
    
    if (songIndex === -1) return `${courseSeq}-${dateStr}${courseMatch[2] || ''}.mp3`;
    if (songIndex === 0) return `${song1Seq}-${dateStr}-歌曲1.mp3`;
    if (songIndex === 1) return `${song2Seq}-${dateStr}-歌曲2.mp3`;
    
    return null;
}

initData();

// ------------------- API -------------------

// 获取所有课程+歌曲（增强版）
app.get('/api/list', async (req, res) => {
    const data = loadData();
    const result = {};
    
    for (const [course, info] of Object.entries(data)) {
        result[course] = {
            ...info,
            course_metadata: null,
            songs_metadata: []
        };
        
        // 获取课程文件元数据
        const coursePath = path.join(SONG_DIR, course);
        if (fs.existsSync(coursePath)) {
            result[course].course_metadata = await getMusicMetadata(coursePath);
        }
        
        // 获取歌曲元数据
        const songs = info.songs || [];
        for (let i = 0; i < songs.length; i++) {
            if (songs[i]) {
                const songPath = path.join(SONG_DIR, songs[i]);
                if (fs.existsSync(songPath)) {
                    result[course].songs_metadata[i] = await getMusicMetadata(songPath);
                } else {
                    result[course].songs_metadata[i] = null;
                }
            } else {
                result[course].songs_metadata[i] = null;
            }
        }
    }
    
    res.json(result);
});

// 获取课程统计信息
app.get('/api/stats', (req, res) => {
    const data = loadData();
    const stats = {
        total_courses: Object.keys(data).length,
        courses_with_songs: 0,
        total_songs: 0,
        empty_slots: 0,
        missing_files: []
    };
    
    for (const [course, info] of Object.entries(data)) {
        let hasSongs = false;
        const songs = info.songs || [];
        for (let i = 0; i < songs.length; i++) {
            if (songs[i]) {
                stats.total_songs++;
                hasSongs = true;
                // 检查文件是否存在
                if (!fs.existsSync(path.join(SONG_DIR, songs[i]))) {
                    stats.missing_files.push(songs[i]);
                }
            } else {
                stats.empty_slots++;
            }
        }
        if (hasSongs) stats.courses_with_songs++;
    }
    
    res.json(stats);
});

// 添加课程
app.post('/api/add-course', (req, res) => {
    const {course} = req.body;
    const data = loadData();
    if (!data[course]) {
        data[course] = {
            songs: [null, null],
            metadata: null,
            renamed_files: []
        };
        saveData(data);
        res.json({message: `课程已添加: ${course}`});
    } else {
        res.json({message: `课程已存在: ${course}`});
    }
});

// 上传歌曲并分配到课程空位
app.post('/api/add-song', upload.single('song'), async (req, res) => {
    const {course, friendly_name} = req.body;
    const file = req.file;
    if (!file) return res.status(400).json({error: '没有上传文件'});

    const data = loadData();
    if (!data[course]) return res.status(400).json({error: '课程不存在'});

    // 找到第一个空位
    const songs = data[course].songs || [];
    const index = songs.indexOf(null);
    if (index === -1) return res.status(400).json({error: '该课程歌曲位置已满'});

    // 解析歌曲信息
    const metadata = await getMusicMetadata(file.path);

    // 生成播放器友好的文件名
    const newName = generatePlaylistName(course, index);
    const newPath = path.join(SONG_DIR, newName);
    fs.renameSync(file.path, newPath);

    // 保存映射
    data[course].songs[index] = newName;
    data[course].renamed_files.push({
        original_name: file.originalname,
        friendly_name: friendly_name || metadata.title,
        playlist_name: newName,
        slot: index,
        metadata: metadata,
        added_time: new Date().toISOString()
    });
    saveData(data);

    res.json({
        message: `歌曲已添加到课程 ${course}`, 
        file: newName, 
        metadata,
        friendly_name: friendly_name || metadata.title
    });
});

// 按友好名称删除歌曲
app.post('/api/remove-song-by-name', (req, res) => {
    const {friendly_name} = req.body;
    const data = loadData();
    
    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        const fileInfo = renamedFiles.find(f => f.friendly_name === friendly_name);
        if (fileInfo) {
            // 删除物理文件
            const filePath = path.join(SONG_DIR, fileInfo.playlist_name);
            if (fs.existsSync(filePath)) {
                fs.unlinkSync(filePath);
            }
            
            // 清空歌曲位置
            if (data[course].songs) {
                data[course].songs[fileInfo.slot] = null;
            }
            
            // 从重命名记录中删除
            data[course].renamed_files = renamedFiles.filter(
                f => f.friendly_name !== friendly_name
            );
            
            saveData(data);
            return res.json({message: `已删除歌曲: ${friendly_name}`});
        }
    }
    
    res.status(404).json({error: '未找到指定歌曲'});
});

// 删除歌曲（按课程和位置）
app.post('/api/remove-song', (req, res) => {
    const {course, slot} = req.body; // slot: 0 或 1
    const data = loadData();
    if (!data[course]) return res.status(400).json({error: '课程不存在'});

    const songs = data[course].songs || [];
    const songName = songs[slot];
    if (!songName) return res.status(400).json({error: '该位置为空'});

    const filePath = path.join(SONG_DIR, songName);
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);

    // 清空位置并删除重命名记录
    data[course].songs[slot] = null;
    data[course].renamed_files = (data[course].renamed_files || []).filter(f => f.slot !== slot);
    saveData(data);
    res.json({message: `已删除 ${songName}`});
});

// 查询歌曲是否存在
app.get('/api/song-exists', (req, res) => {
    const {name} = req.query;
    const data = loadData();
    
    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        const found = renamedFiles.find(f => 
            f.friendly_name.toLowerCase().includes(name.toLowerCase()) ||
            f.original_name.toLowerCase().includes(name.toLowerCase())
        );
        if (found) {
            return res.json({
                exists: true,
                course: course,
                info: found
            });
        }
    }
    
    res.json({exists: false});
});

// 获取所有歌曲列表
app.get('/api/songs', (req, res) => {
    const data = loadData();
    const songs = [];
    
    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        renamedFiles.forEach(file => {
            songs.push({
                ...file,
                course: course
            });
        });
    }
    
    res.json(songs);
});

// 批量重命名为播放器友好格式
app.post('/api/batch-rename', (req, res) => {
    const data = loadData();
    const renamedFiles = [];
    
    for (const [course, info] of Object.entries(data)) {
        // 重命名课程文件
        const courseMatch = course.match(/(\d{8})(-\d+)?\.mp3$/);
        if (courseMatch) {
            const newCourseName = generatePlaylistName(course, -1);
            if (newCourseName && newCourseName !== course) {
                const oldPath = path.join(SONG_DIR, course);
                const newPath = path.join(SONG_DIR, newCourseName);
                if (fs.existsSync(oldPath)) {
                    fs.renameSync(oldPath, newPath);
                    renamedFiles.push({from: course, to: newCourseName});
                }
            }
        }
        
        // 重命名歌曲文件
        const songs = info.songs || [];
        songs.forEach((song, index) => {
            if (song) {
                const newSongName = generatePlaylistName(course, index);
                if (newSongName && newSongName !== song) {
                    const oldPath = path.join(SONG_DIR, song);
                    const newPath = path.join(SONG_DIR, newSongName);
                    if (fs.existsSync(oldPath)) {
                        fs.renameSync(oldPath, newPath);
                        data[course].songs[index] = newSongName;
                        renamedFiles.push({from: song, to: newSongName});
                        
                        // 更新重命名记录
                        const renamedFilesList = data[course].renamed_files || [];
                        const fileRecord = renamedFilesList.find(f => f.slot === index);
                        if (fileRecord) {
                            fileRecord.playlist_name = newSongName;
                        }
                    }
                }
            }
        });
    }
    
    saveData(data);
    res.json({message: '批量重命名完成', renamed: renamedFiles});
});

// ------------------- HTML 页面 -------------------
app.get('/', (req, res) => {
    res.send(generateHTML());
});

function generateHTML() {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎵 课程音乐管理系统</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh; padding: 20px;
        }
        .container {
            max-width: 1200px; margin: 0 auto; background: white;
            border-radius: 15px; box-shadow: 0 20px 40px rgba(0,0,0,0.1); overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white; padding: 30px; text-align: center;
        }
        .header h1 { font-size: 2.5rem; margin-bottom: 10px; }
        .header p { font-size: 1.1rem; opacity: 0.9; }
        .tabs {
            display: flex; background: #f8f9fa; border-bottom: 2px solid #e9ecef;
        }
        .tab {
            flex: 1; padding: 15px 20px; text-align: center; cursor: pointer;
            transition: all 0.3s ease; border: none; background: none;
            font-size: 1rem; font-weight: 500;
        }
        .tab.active {
            background: white; color: #667eea; border-bottom: 3px solid #667eea;
        }
        .tab:hover { background: #e9ecef; }
        .content { padding: 30px; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .stats-grid {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px; margin-bottom: 30px;
        }
        .stat-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white; padding: 20px; border-radius: 10px; text-align: center;
        }
        .stat-number { font-size: 2rem; font-weight: bold; margin-bottom: 5px; }
        .stat-label { font-size: 0.9rem; opacity: 0.9; }
        .course-grid { display: grid; gap: 20px; }
        .course-card {
            border: 1px solid #e9ecef; border-radius: 10px; overflow: hidden;
            transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        .course-card:hover {
            transform: translateY(-5px); box-shadow: 0 10px 25px rgba(0,0,0,0.1);
        }
        .course-header {
            background: #f8f9fa; padding: 15px 20px; border-bottom: 1px solid #e9ecef;
        }
        .course-title {
            font-size: 1.2rem; font-weight: 600; color: #495057; margin-bottom: 5px;
        }
        .course-date { font-size: 0.9rem; color: #6c757d; }
        .course-body { padding: 20px; }
        .song-slot {
            display: flex; align-items: center; justify-content: space-between;
            padding: 10px 0; border-bottom: 1px solid #f8f9fa;
        }
        .song-slot:last-child { border-bottom: none; }
        .song-info { flex: 1; }
        .song-title { font-weight: 500; color: #495057; margin-bottom: 3px; }
        .song-meta { font-size: 0.85rem; color: #6c757d; }
        .empty-slot { color: #adb5bd; font-style: italic; }
        .btn {
            padding: 8px 16px; border: none; border-radius: 5px; cursor: pointer;
            font-size: 0.85rem; transition: all 0.2s ease; text-decoration: none;
            display: inline-block; margin: 2px;
        }
        .btn-primary { background: #667eea; color: white; }
        .btn-primary:hover { background: #5a6fd8; }
        .btn-danger { background: #dc3545; color: white; }
        .btn-danger:hover { background: #c82333; }
        .btn-secondary { background: #6c757d; color: white; }
        .btn-secondary:hover { background: #5a6268; }
        .form-group { margin-bottom: 20px; }
        .form-label {
            display: block; margin-bottom: 5px; font-weight: 500; color: #495057;
        }
        .form-control {
            width: 100%; padding: 10px 15px; border: 1px solid #ced4da;
            border-radius: 5px; font-size: 1rem; transition: border-color 0.2s ease;
        }
        .form-control:focus {
            outline: none; border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        .search-box { position: relative; margin-bottom: 30px; }
        .search-box input { padding-left: 40px; }
        .search-icon {
            position: absolute; left: 15px; top: 50%; transform: translateY(-50%);
            color: #6c757d;
        }
        .song-list { display: grid; gap: 15px; }
        .song-item {
            background: #f8f9fa; padding: 15px; border-radius: 8px;
            border-left: 4px solid #667eea;
        }
        .loading { text-align: center; padding: 40px; color: #6c757d; }
        .alert {
            padding: 15px; border-radius: 5px; margin-bottom: 20px;
        }
        .alert-success {
            background: #d4edda; color: #155724; border: 1px solid #c3e6cb;
        }
        .alert-error {
            background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb;
        }
        @media (max-width: 768px) {
            .tabs { flex-direction: column; }
            .stats-grid { grid-template-columns: 1fr 1fr; }
            .content { padding: 20px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎵 课程音乐管理系统</h1>
            <p>智能管理您的课程与歌曲播放列表</p>
        </div>

        <div class="tabs">
            <button class="tab active" onclick="showTab('overview')">📊 概览</button>
            <button class="tab" onclick="showTab('courses')">📚 课程管理</button>
            <button class="tab" onclick="showTab('songs')">🎵 歌曲管理</button>
            <button class="tab" onclick="showTab('tools')">🔧 工具</button>
        </div>

        <div class="content">
            <div id="overview" class="tab-content active">
                <div class="stats-grid" id="stats-grid">
                    <div class="loading">正在加载统计信息...</div>
                </div>
                <h3 style="margin-bottom: 20px;">📋 最近添加的歌曲</h3>
                <div id="recent-songs" class="song-list">
                    <div class="loading">正在加载...</div>
                </div>
            </div>

            <div id="courses" class="tab-content">
                <div class="search-box">
                    <span class="search-icon">🔍</span>
                    <input type="text" class="form-control" id="course-search" placeholder="搜索课程...">
                </div>
                <div id="courses-grid" class="course-grid">
                    <div class="loading">正在加载课程...</div>
                </div>
            </div>

            <div id="songs" class="tab-content">
                <div class="form-group">
                    <label class="form-label">🎵 添加新歌曲</label>
                    <select class="form-control" id="course-select" style="margin-bottom: 10px;">
                        <option value="">选择课程...</option>
                    </select>
                    <input type="file" class="form-control" id="song-file" accept=".mp3" style="margin-bottom: 10px;">
                    <input type="text" class="form-control" id="friendly-name" placeholder="友好名称（可选）" style="margin-bottom: 10px;">
                    <button class="btn btn-primary" onclick="addSong()">添加歌曲</button>
                </div>
                <hr style="margin: 30px 0;">
                <div class="form-group">
                    <label class="form-label">🗑️ 删除歌曲</label>
                    <input type="text" class="form-control" id="delete-song-name" placeholder="输入歌曲名称..." style="margin-bottom: 10px;">
                    <button class="btn btn-danger" onclick="deleteSongByName()">删除歌曲</button>
                </div>
                <hr style="margin: 30px 0;">
                <div class="search-box">
                    <span class="search-icon">🔍</span>
                    <input type="text" class="form-control" id="song-search" placeholder="搜索歌曲..." onkeyup="searchSongs()">
                </div>
                <div id="songs-list" class="song-list">
                    <div class="loading">正在加载歌曲...</div>
                </div>
            </div>

            <div id="tools" class="tab-content">
                <div class="form-group">
                    <label class="form-label">🔄 批量重命名</label>
                    <p style="color: #6c757d; margin-bottom: 15px;">将所有文件重命名为播放器友好的格式（001-xxx.mp3, 002-xxx.mp3...）</p>
                    <button class="btn btn-secondary" onclick="batchRename()">执行批量重命名</button>
                </div>
                <hr style="margin: 30px 0;">
                <div class="form-group">
                    <label class="form-label">🔍 查询歌曲</label>
                    <input type="text" class="form-control" id="query-song" placeholder="输入歌曲名称..." style="margin-bottom: 10px;">
                    <button class="btn btn-primary" onclick="querySong()">查询</button>
                    <div id="query-result" style="margin-top: 15px;"></div>
                </div>
            </div>
        </div>
    </div>
    <script src="data:text/javascript;base64,${Buffer.from(`
        let allData = {};
        let allSongs = [];
        function showTab(tabName) {
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.getElementById(tabName).classList.add('active');
            event.target.classList.add('active');
            if (tabName === 'overview') loadOverview();
            if (tabName === 'courses') loadCourses();
            if (tabName === 'songs') loadSongs();
        }
        async function loadOverview() {
            try {
                const [statsRes, songsRes] = await Promise.all([fetch('/api/stats'), fetch('/api/songs')]);
                const [stats, songs] = await Promise.all([statsRes.json(), songsRes.json()]);
                document.getElementById('stats-grid').innerHTML = \`
                    <div class="stat-card"><div class="stat-number">\${stats.total_courses}</div><div class="stat-label">总课程数</div></div>
                    <div class="stat-card"><div class="stat-number">\${stats.total_songs}</div><div class="stat-label">总歌曲数</div></div>
                    <div class="stat-card"><div class="stat-number">\${stats.courses_with_songs}</div><div class="stat-label">有歌曲的课程</div></div>
                    <div class="stat-card"><div class="stat-number">\${stats.empty_slots}</div><div class="stat-label">空闲位置</div></div>\`;
                const recent = songs.sort((a,b) => new Date(b.added_time) - new Date(a.added_time)).slice(0,5);
                document.getElementById('recent-songs').innerHTML = recent.length ? recent.map(s => \`<div class="song-item"><div class="song-title">\${s.friendly_name}</div><div class="song-meta">🎤 \${s.metadata.artist} | 📅 \${s.metadata.year} | 📚 \${s.course}</div></div>\`).join('') : '<div class="empty-slot">暂无歌曲</div>';
            } catch (e) { console.error('加载失败:', e); }
        }
        async function loadCourses() {
            try {
                allData = await (await fetch('/api/list')).json();
                displayCourses(allData);
            } catch (e) { console.error('加载失败:', e); }
        }
        function displayCourses(data) {
            const grid = document.getElementById('courses-grid');
            const courses = Object.entries(data).sort(([a],[b]) => a.localeCompare(b));
            grid.innerHTML = courses.length ? courses.map(([course, info]) => {
                const dateMatch = course.match(/(\\d{4})(\\d{2})(\\d{2})/);
                const dateStr = dateMatch ? \`\${dateMatch[1]}-\${dateMatch[2]}-\${dateMatch[3]}\` : course;
                const songsHtml = info.songs.map((song, i) => {
                    if (song) {
                        const fileInfo = info.renamed_files.find(f => f.slot === i);
                        const meta = info.songs_metadata[i];
                        return \`<div class="song-slot"><div class="song-info"><div class="song-title">\${fileInfo ? fileInfo.friendly_name : song}</div><div class="song-meta">🎤 \${meta?.artist || '未知'} | 📅 \${meta?.year || '未知'}</div></div><div><a href="/songs/\${song}" target="_blank" class="btn btn-primary">播放</a><button class="btn btn-danger" onclick="removeSong('\${course}',\${i})">删除</button></div></div>\`;
                    } else {
                        return \`<div class="song-slot"><div class="song-info empty-slot">空位 \${i + 1}</div></div>\`;
                    }
                }).join('');
                return \`<div class="course-card"><div class="course-header"><div class="course-title">\${course}</div><div class="course-date">📅 \${dateStr}</div></div><div class="course-body">\${songsHtml}</div></div>\`;
            }).join('') : '<div class="empty-slot">暂无课程</div>';
        }
        async function loadSongs() {
            try {
                const [songsRes, dataRes] = await Promise.all([fetch('/api/songs'), fetch('/api/list')]);
                const [songs, data] = await Promise.all([songsRes.json(), dataRes.json()]);
                allSongs = songs;
                document.getElementById('course-select').innerHTML = '<option value="">选择课程...</option>' + Object.keys(data).sort().map(c => \`<option value="\${c}">\${c}</option>\`).join('');
                displaySongs(allSongs);
            } catch (e) { console.error('加载失败:', e); }
        }
        function displaySongs(songs) {
            document.getElementById('songs-list').innerHTML = songs.length ? songs.map(s => \`<div class="song-item"><div class="song-title">\${s.friendly_name}</div><div class="song-meta">🎤 \${s.metadata.artist} | 📅 \${s.metadata.year} | 📚 \${s.course} | 📁 \${s.playlist_name}</div></div>\`).join('') : '<div class="empty-slot">暂无歌曲</div>';
        }
        function searchSongs() {
            const q = document.getElementById('song-search').value.toLowerCase();
            displaySongs(allSongs.filter(s => s.friendly_name.toLowerCase().includes(q) || s.metadata.artist.toLowerCase().includes(q) || s.course.toLowerCase().includes(q)));
        }
        async function addSong() {
            const course = document.getElementById('course-select').value;
            const file = document.getElementById('song-file').files[0];
            const name = document.getElementById('friendly-name').value;
            if (!course || !file) return alert('请选择课程和文件');
            const form = new FormData();
            form.append('course', course);
            form.append('song', file);
            if (name) form.append('friendly_name', name);
            try {
                const res = await fetch('/api/add-song', {method: 'POST', body: form});
                const result = await res.json();
                if (res.ok) {
                    showAlert('歌曲添加成功: ' + result.friendly_name, 'success');
                    document.getElementById('song-file').value = '';
                    document.getElementById('friendly-name').value = '';
                    loadSongs();
                } else showAlert('添加失败: ' + result.error, 'error');
            } catch (e) { showAlert('添加失败: ' + e.message, 'error'); }
        }
        async function deleteSongByName() {
            const name = document.getElementById('delete-song-name').value;
            if (!name) return alert('请输入歌曲名称');
            if (!confirm('确定删除 "' + name + '"？')) return;
            try {
                const res = await fetch('/api/remove-song-by-name', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({friendly_name: name})});
                const result = await res.json();
                if (res.ok) {
                    showAlert(result.message, 'success');
                    document.getElementById('delete-song-name').value = '';
                    loadSongs(); loadCourses();
                } else showAlert('删除失败: ' + result.error, 'error');
            } catch (e) { showAlert('删除失败: ' + e.message, 'error'); }
        }
        async function removeSong(course, slot) {
            if (!confirm('确定删除？')) return;
            try {
                const res = await fetch('/api/remove-song', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({course, slot})});
                const result = await res.json();
                if (res.ok) { showAlert(result.message, 'success'); loadCourses(); loadSongs(); }
                else showAlert('删除失败: ' + result.error, 'error');
            } catch (e) { showAlert('删除失败: ' + e.message, 'error'); }
        }
        async function batchRename() {
            if (!confirm('确定批量重命名？')) return;
            try {
                const res = await fetch('/api/batch-rename', {method: 'POST', headers: {'Content-Type': 'application/json'}});
                const result = await res.json();
                showAlert(result.message + '，重命名了 ' + result.renamed.length + ' 个文件', 'success');
                loadCourses();
            } catch (e) { showAlert('失败: ' + e.message, 'error'); }
        }
        async function querySong() {
            const name = document.getElementById('query-song').value;
            if (!name) return;
            try {
                const res = await fetch('/api/song-exists?name=' + encodeURIComponent(name));
                const result = await res.json();
                document.getElementById('query-result').innerHTML = result.exists ? \`<div class="alert alert-success"><strong>找到歌曲！</strong><br>友好名称: \${result.info.friendly_name}<br>所属课程: \${result.course}<br>艺术家: \${result.info.metadata.artist}<br>年份: \${result.info.metadata.year}<br>文件名: \${result.info.playlist_name}</div>\` : '<div class="alert alert-error">未找到匹配的歌曲</div>';
            } catch (e) { document.getElementById('query-result').innerHTML = '<div class="alert alert-error">查询失败</div>'; }
        }
        function showAlert(msg, type) {
            const alert = document.createElement('div');
            alert.className = \`alert alert-\${type}\`;
            alert.textContent = msg;
            alert.style.cssText = 'position:fixed;top:20px;right:20px;z-index:9999;max-width:400px';
            document.body.appendChild(alert);
            setTimeout(() => alert.remove(), 5000);
        }
        document.addEventListener('DOMContentLoaded', loadOverview);
    `).toString('base64')}"></script>
</body>
</html>`;
}

// ------------------- 启动 -------------------
app.listen(PORT, () => {
    console.log(`Server running at http://localhost:${PORT}`);
});
