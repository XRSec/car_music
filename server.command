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
const upload = multer({
    dest: SONG_DIR,
    fileFilter: (req, file, cb) => {
        // 修复中文文件名编码问题
        file.originalname = Buffer.from(file.originalname, 'latin1').toString('utf8');
        cb(null, true);
    }
});
const uploadMultiple = multer({
    dest: SONG_DIR,
    fileFilter: (req, file, cb) => {
        // 修复中文文件名编码问题
        file.originalname = Buffer.from(file.originalname, 'latin1').toString('utf8');
        cb(null, true);
    }
}).array('songs', 100); // 支持最多100个文件（分批处理）

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

// 获取音乐元数据（包括封面图片）
async function getMusicMetadata(filePath) {
    try {
        const metadata = await mm.parseFile(filePath, {
            skipCovers: false,
            skipPostHeaders: false,
            includeChapters: false
        });
        let albumArt = null;

        // 提取封面图片
        if (metadata.common && metadata.common.picture && metadata.common.picture.length > 0) {
            try {
                const picture = metadata.common.picture[0];
                if (picture.data && picture.format) {
                    albumArt = {
                        format: picture.format,
                        data: picture.data.toString('base64')
                    };
                }
            } catch (pictureError) {
                console.warn(`封面提取失败 ${filePath}:`, pictureError.message);
            }
        }

        return {
            title: metadata.common?.title || path.basename(filePath, '.mp3'),
            artist: metadata.common?.artist || '未知艺术家',
            album: metadata.common?.album || '未知专辑',
            year: metadata.common?.year || '未知年份',
            genre: metadata.common?.genre ? metadata.common.genre.join(', ') : '未知流派',
            duration: metadata.format?.duration ? Math.round(metadata.format.duration) : 0,
            albumArt: albumArt
        };
    } catch (error) {
        console.warn(`元数据提取失败 ${filePath}:`, error.message);
        return {
            title: path.basename(filePath, '.mp3'),
            artist: '未知艺术家',
            album: '未知专辑',
            year: '未知年份',
            genre: '未知流派',
            duration: 0,
            albumArt: null
        };
    }
}

// 生成播放器友好的文件名（课程名-A/B格式）
function generatePlaylistName(courseFile, songIndex) {
    const courseMatch = courseFile.match(/(\d{8})(-\d+)?/);
    if (!courseMatch) return null;

    const baseName = courseFile.replace('.mp3', '');

    // 课程文件保持原名
    if (songIndex === -1) return courseFile;

    // 歌曲文件：课程名-A.mp3, 课程名-B.mp3
    const songSuffix = songIndex === 0 ? 'A' : 'B';
    return `${baseName}-${songSuffix}.mp3`;
}



// 自动分配课程（找到有空位的课程）
function findAvailableCourse(data) {
    const courses = Object.keys(data).sort();
    for (const course of courses) {
        const songs = data[course].songs || [];
        const emptyIndex = songs.indexOf(null);
        if (emptyIndex !== -1) {
            return { course, slot: emptyIndex };
        }
    }
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
    const {course: targetCourse, friendly_name} = req.body;
    const file = req.file;
    if (!file) return res.status(400).json({error: '没有上传文件'});

    const data = loadData();

    // 确定目标课程和位置
    let assignedCourse = targetCourse;
    let index;

    if (!assignedCourse) {
        // 自动分配到有空位的课程
        const available = findAvailableCourse(data);
        if (!available) {
            fs.unlinkSync(file.path);
            return res.status(400).json({error: '没有可用的空位'});
        }
        assignedCourse = available.course;
        index = available.slot;
    } else {
        // 检查指定课程
        if (!data[assignedCourse]) {
            fs.unlinkSync(file.path);
            return res.status(400).json({error: '课程不存在'});
        }

        const songs = data[assignedCourse].songs || [];
        index = songs.indexOf(null);
        if (index === -1) {
            // 指定课程满了，尝试自动分配
            const available = findAvailableCourse(data);
            if (!available) {
                fs.unlinkSync(file.path);
                return res.status(400).json({error: '指定课程已满且没有其他可用空位'});
            }
            assignedCourse = available.course;
            index = available.slot;
        }
    }

    // 检查文件名是否重复
    const originalName = file.originalname;
    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        if (renamedFiles.find(f => f.original_name === originalName)) {
            fs.unlinkSync(file.path);
            return res.status(400).json({error: `文件名重复: ${originalName} 已存在，请重命名后再上传`});
        }
    }

    // 解析歌曲信息
    const metadata = await getMusicMetadata(file.path);

    // 生成播放器友好的文件名
    const newName = generatePlaylistName(assignedCourse, index);
    const newPath = path.join(SONG_DIR, newName);
    fs.renameSync(file.path, newPath);

    // 保存映射
    data[assignedCourse].songs[index] = newName;
    data[assignedCourse].renamed_files = data[assignedCourse].renamed_files || [];
    data[assignedCourse].renamed_files.push({
        original_name: originalName,
        friendly_name: originalName.replace('.mp3', ''), // 使用原文件名作为友好名称
        playlist_name: newName,
        slot: index,
        metadata: metadata,
        added_time: new Date().toISOString()
    });
    saveData(data);

    res.json({
        message: `歌曲已添加到课程 ${assignedCourse}`,
        file: newName,
        metadata,
        friendly_name: originalName.replace('.mp3', ''),
        auto_assigned: targetCourse !== assignedCourse
    });
});

// 批量上传歌曲
app.post('/api/add-songs-batch', uploadMultiple, async (req, res) => {
    const { course: targetCourse, friendly_names } = req.body;
    const files = req.files;

    if (!files || files.length === 0) {
        return res.status(400).json({error: '没有上传文件'});
    }

    const data = loadData();
    const results = [];
    const errors = [];

    for (let i = 0; i < files.length; i++) {
        const file = files[i];

        try {
            // 检查文件名是否重复
            const originalName = file.originalname;
            let isDuplicate = false;
            for (const [course, info] of Object.entries(data)) {
                const renamedFiles = info.renamed_files || [];
                if (renamedFiles.find(f => f.original_name === originalName)) {
                    isDuplicate = true;
                    break;
                }
            }
            
            if (isDuplicate) {
                errors.push({
                    file: originalName,
                    error: `文件名重复: ${originalName} 已存在，请重命名后再上传`
                });
                fs.unlinkSync(file.path);
                continue;
            }

            // 确定目标课程
            let assignedCourse = targetCourse;
            let assignedSlot;

            if (!assignedCourse) {
                // 自动分配到有空位的课程
                const available = findAvailableCourse(data);
                if (!available) {
                    errors.push({
                        file: file.originalname,
                        error: '没有可用的空位'
                    });
                    fs.unlinkSync(file.path); // 删除临时文件
                    continue;
                }
                assignedCourse = available.course;
                assignedSlot = available.slot;
            } else {
                // 检查指定课程是否有空位
                if (!data[assignedCourse]) {
                    errors.push({
                        file: file.originalname,
                        error: '指定课程不存在'
                    });
                    fs.unlinkSync(file.path);
                    continue;
                }

                const songs = data[assignedCourse].songs || [];
                assignedSlot = songs.indexOf(null);
                if (assignedSlot === -1) {
                    // 当前课程满了，尝试自动分配
                    const available = findAvailableCourse(data);
                    if (!available) {
                        errors.push({
                            file: file.originalname,
                            error: '指定课程已满且没有其他可用空位'
                        });
                        fs.unlinkSync(file.path);
                        continue;
                    }
                    assignedCourse = available.course;
                    assignedSlot = available.slot;
                }
            }

            // 解析歌曲信息
            const metadata = await getMusicMetadata(file.path);

            // 生成播放器友好的文件名
            const newName = generatePlaylistName(assignedCourse, assignedSlot);
            const newPath = path.join(SONG_DIR, newName);
            fs.renameSync(file.path, newPath);

            // 保存映射
            data[assignedCourse].songs[assignedSlot] = newName;
            data[assignedCourse].renamed_files = data[assignedCourse].renamed_files || [];
            data[assignedCourse].renamed_files.push({
                original_name: originalName,
                friendly_name: originalName.replace('.mp3', ''), // 使用原文件名作为友好名称
                playlist_name: newName,
                slot: assignedSlot,
                metadata: metadata,
                added_time: new Date().toISOString()
            });

            results.push({
                original: file.originalname,
                friendly_name: originalName.replace('.mp3', ''),
                course: assignedCourse,
                slot: assignedSlot,
                playlist_name: newName,
                metadata: metadata
            });

        } catch (error) {
            errors.push({
                file: file.originalname,
                error: error.message
            });
            if (fs.existsSync(file.path)) {
                fs.unlinkSync(file.path);
            }
        }
    }

    saveData(data);

    res.json({
        message: `批量上传完成：成功 ${results.length} 个，失败 ${errors.length} 个`,
        success: results,
        errors: errors,
        total: files.length
    });
});

// 直接上传到指定课程的指定位置
app.post('/api/add-song-to-slot', upload.single('song'), async (req, res) => {
    const {course, slot, friendly_name} = req.body;
    const file = req.file;

    if (!file) return res.status(400).json({error: '没有上传文件'});
    if (!course || slot === undefined) {
        fs.unlinkSync(file.path);
        return res.status(400).json({error: '缺少课程或位置参数'});
    }

    const data = loadData();
    if (!data[course]) {
        fs.unlinkSync(file.path);
        return res.status(400).json({error: '课程不存在'});
    }

    const slotIndex = parseInt(slot);
    if (slotIndex < 0 || slotIndex >= 2) {
        fs.unlinkSync(file.path);
        return res.status(400).json({error: '位置参数无效'});
    }

    const songs = data[course].songs || [];
    if (songs[slotIndex] !== null) {
        fs.unlinkSync(file.path);
        return res.status(400).json({error: '该位置已有歌曲'});
    }

    // 检查文件名是否重复
    const originalName = file.originalname;
    for (const [courseName, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        if (renamedFiles.find(f => f.original_name === originalName)) {
            fs.unlinkSync(file.path);
            return res.status(400).json({error: `文件名重复: ${originalName} 已存在，请重命名后再上传`});
        }
    }

    try {
        // 解析歌曲信息
        const metadata = await getMusicMetadata(file.path);

        // 生成播放器友好的文件名
        const newName = generatePlaylistName(course, slotIndex);
        const newPath = path.join(SONG_DIR, newName);
        fs.renameSync(file.path, newPath);

        // 保存映射
        data[course].songs[slotIndex] = newName;
        data[course].renamed_files = data[course].renamed_files || [];
        data[course].renamed_files.push({
            original_name: originalName,
            friendly_name: originalName.replace('.mp3', ''), // 使用原文件名作为友好名称
            playlist_name: newName,
            slot: slotIndex,
            metadata: metadata,
            added_time: new Date().toISOString()
        });
        saveData(data);

        res.json({
            message: `歌曲已添加到课程 ${course} 的位置 ${slotIndex + 1}`,
            file: newName,
            metadata,
            friendly_name: originalName.replace('.mp3', '')
        });
    } catch (error) {
        if (fs.existsSync(file.path)) fs.unlinkSync(file.path);
        res.status(500).json({error: '处理文件失败: ' + error.message});
    }
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
            let fileDeleted = false;
            if (fs.existsSync(filePath)) {
                try {
                    fs.unlinkSync(filePath);
                    fileDeleted = true;
                } catch (error) {
                    console.error(`删除文件失败: ${filePath}`, error);
                }
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
            const message = fileDeleted ? `已删除歌曲: ${friendly_name}` : `已从数据库删除歌曲: ${friendly_name}（物理文件可能不存在）`;
            return res.json({message: message});
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
    let fileDeleted = false;
    if (fs.existsSync(filePath)) {
        try {
            fs.unlinkSync(filePath);
            fileDeleted = true;
        } catch (error) {
            console.error(`删除文件失败: ${filePath}`, error);
        }
    }

    // 清空位置并删除重命名记录
    data[course].songs[slot] = null;
    data[course].renamed_files = (data[course].renamed_files || []).filter(f => f.slot !== slot);
    saveData(data);
    
    const message = fileDeleted ? `已删除 ${songName}` : `已从数据库删除 ${songName}（物理文件可能不存在）`;
    res.json({message: message});
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

// 获取歌曲封面图片
app.get('/api/album-art/:filename', async (req, res) => {
    const filename = req.params.filename;
    const filePath = path.join(SONG_DIR, filename);

    if (!fs.existsSync(filePath)) {
        return res.status(404).json({error: '文件不存在'});
    }

    try {
        const metadata = await mm.parseFile(filePath, {
            skipCovers: false,
            skipPostHeaders: true,
            includeChapters: false
        });

        if (metadata.common && metadata.common.picture && metadata.common.picture.length > 0) {
            const picture = metadata.common.picture[0];
            if (picture.data && picture.format) {
                res.set('Content-Type', picture.format);
                res.set('Cache-Control', 'public, max-age=86400'); // 缓存1天
                res.send(picture.data);
            } else {
                res.status(404).json({error: '封面数据损坏'});
            }
        } else {
            res.status(404).json({error: '没有封面图片'});
        }
    } catch (error) {
        console.warn(`读取封面失败 ${filePath}:`, error.message);
        res.status(500).json({error: '读取封面失败: ' + error.message});
    }
});

// 一键还原功能 - 复制所有音乐到music文件夹并还原原始名称
app.post('/api/restore-music', (req, res) => {
    const data = loadData();
    const musicDir = path.join(SONG_DIR, 'music');

    // 创建music文件夹
    if (!fs.existsSync(musicDir)) {
        fs.mkdirSync(musicDir);
    }

    const restoredFiles = [];
    const errors = [];

    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];

        // 还原歌曲文件
        renamedFiles.forEach(fileRecord => {
            try {
                const currentPath = path.join(SONG_DIR, fileRecord.playlist_name);
                const restoredPath = path.join(musicDir, fileRecord.original_name);

                if (fs.existsSync(currentPath)) {
                    fs.copyFileSync(currentPath, restoredPath);
                    restoredFiles.push({
                        friendly_name: fileRecord.friendly_name,
                        original_name: fileRecord.original_name,
                        playlist_name: fileRecord.playlist_name
                    });
                } else {
                    errors.push({
                        file: fileRecord.playlist_name,
                        error: '源文件不存在'
                    });
                }
            } catch (error) {
                errors.push({
                    file: fileRecord.playlist_name,
                    error: error.message
                });
            }
        });

        // 还原课程文件
        try {
            const coursePath = path.join(SONG_DIR, course);
            const restoredCoursePath = path.join(musicDir, course);

            if (fs.existsSync(coursePath)) {
                fs.copyFileSync(coursePath, restoredCoursePath);
                restoredFiles.push({
                    friendly_name: course,
                    original_name: course,
                    playlist_name: course
                });
            }
        } catch (error) {
            errors.push({
                file: course,
                error: error.message
            });
        }
    }

    res.json({
        message: `还原完成：成功 ${restoredFiles.length} 个文件，失败 ${errors.length} 个`,
        restored: restoredFiles,
        errors: errors,
        music_folder: musicDir
    });
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
            cursor: pointer; transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        .stat-card:hover {
            transform: translateY(-3px); box-shadow: 0 15px 30px rgba(0,0,0,0.2);
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
        .empty-slot-upload {
            border: 2px dashed #ced4da; border-radius: 8px; padding: 20px;
            text-align: center; cursor: pointer; transition: all 0.3s ease;
            background: #f8f9fa; margin: 5px 0;
        }
        .empty-slot-upload:hover, .empty-slot-upload.dragover {
            border-color: #667eea; background: #e7f3ff; color: #667eea;
        }
        .empty-slot-upload .upload-icon { font-size: 1.5rem; margin-bottom: 8px; }
        .empty-slot-upload .upload-text { font-size: 0.9rem; }
        .course-info { 
            background: #e3f2fd; padding: 15px; border-radius: 5px; margin-bottom: 15px;
            border-left: 4px solid #2196f3; display: flex; align-items: center;
            justify-content: space-between;
        }
        .course-title-info { font-weight: 600; color: #1976d2; flex: 1; }
        .course-meta-info { font-size: 0.9rem; color: #666; margin-left: 15px; }
        .course-play-btn { margin-left: 20px; }
        .collapsible-section {
            border: 1px solid #e9ecef; border-radius: 8px; margin-bottom: 20px;
            overflow: hidden;
        }
        .collapsible-section summary {
            background: #f8f9fa; padding: 15px 20px; cursor: pointer;
            font-weight: 600; color: #495057; list-style: none;
            display: flex; align-items: center; justify-content: space-between;
        }
        .collapsible-section summary:hover {
            background: #e9ecef;
        }
        .collapsible-section summary::after {
            content: '▼'; transition: transform 0.3s ease;
        }
        .collapsible-section[open] summary::after {
            transform: rotate(180deg);
        }
        .collapsible-content {
            padding: 20px;
        }
        .empty-slots-row {
            display: flex; gap: 15px; margin-top: 10px;
        }
        .empty-slot-upload {
            border: 2px dashed #ced4da; border-radius: 8px; padding: 15px;
            text-align: center; cursor: pointer; transition: all 0.3s ease;
            background: #f8f9fa; flex: 1; min-height: 80px;
            display: flex; flex-direction: column; justify-content: center;
        }
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
        .drop-zone {
            border: 2px dashed #ced4da; border-radius: 10px; padding: 40px;
            text-align: center; transition: all 0.3s ease; cursor: pointer;
            background: #f8f9fa; margin-bottom: 15px;
        }
        .drop-zone:hover, .drop-zone.dragover {
            border-color: #667eea; background: #e7f3ff;
        }
        .drop-content { pointer-events: none; }
        .drop-icon { font-size: 3rem; margin-bottom: 15px; }
        .drop-text { font-size: 1.1rem; color: #495057; margin-bottom: 20px; }
        .file-item {
            display: flex; justify-content: space-between; align-items: center;
            padding: 10px; background: #f8f9fa; border-radius: 5px; margin-bottom: 10px;
        }
        .file-info { flex: 1; }
        .file-name { font-weight: 500; }
        .file-size { font-size: 0.85rem; color: #6c757d; }
        .progress-bar {
            width: 100%; height: 20px; background: #e9ecef; border-radius: 10px;
            overflow: hidden; margin-bottom: 10px;
        }
        .progress-fill {
            height: 100%; background: linear-gradient(90deg, #667eea, #764ba2);
            width: 0%; transition: width 0.3s ease;
        }
        @media (max-width: 768px) {
            .tabs { flex-direction: column; }
            .stats-grid { grid-template-columns: 1fr 1fr; }
            .content { padding: 20px; }
            .drop-zone { padding: 20px; }
            .drop-icon { font-size: 2rem; }
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
                    <input type="text" class="form-control" id="course-search" placeholder="搜索课程标题、文件名、年份..." oninput="searchCourses()">
                </div>

                <details class="collapsible-section" open>
                    <summary>🎵 有两首歌曲的课程</summary>
                    <div class="collapsible-content">
                        <div id="courses-full" class="course-grid">
                            <div class="loading">正在加载...</div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section" open>
                    <summary>🎶 有一首歌曲的课程</summary>
                    <div class="collapsible-content">
                        <div id="courses-partial" class="course-grid">
                            <div class="loading">正在加载...</div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section" open>
                    <summary>📚 没有歌曲的课程</summary>
                    <div class="collapsible-content">
                        <div id="courses-empty" class="course-grid">
                            <div class="loading">正在加载...</div>
                        </div>
                    </div>
                </details>
            </div>

            <div id="songs" class="tab-content">
                <details class="collapsible-section" open>
                    <summary>🎵 添加歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <select class="form-control" id="course-select" style="margin-bottom: 10px;">
                                <option value="">自动分配到有空位的课程</option>
                            </select>
                            
                            <!-- 拖拽上传区域 -->
                            <div id="drop-zone" class="drop-zone">
                                <div class="drop-content">
                                    <div class="drop-icon">📁</div>
                                    <div class="drop-text">
                                        <strong>拖拽 MP3 文件到这里</strong><br>
                                        或点击选择文件
                                    </div>
                                    <input type="file" id="song-files" multiple accept=".mp3" style="display: none;">
                                    <button class="btn btn-primary" onclick="document.getElementById('song-files').click()">选择文件</button>
                                </div>
                            </div>
                            
                            <!-- 文件列表 -->
                            <div id="file-list" style="margin-top: 15px; display: none;">
                                <h4>准备上传的文件：</h4>
                                <!-- 上传控制区域 -->
                                <div style="background: #f8f9fa; padding: 15px; border-radius: 8px; margin-bottom: 15px; border: 1px solid #e9ecef;">
                                    <p style="margin: 0 0 10px 0; color: #6c757d; font-size: 0.9em;">
                                        💡 文件将自动重命名为"课程-A.mp3"格式，原文件名将保存为显示名称
                                    </p>
                                    <div style="display: flex; gap: 10px;">
                                        <button class="btn btn-primary" onclick="uploadBatchFiles()" style="flex: 1;">
                                            📤 开始批量上传
                                        </button>
                                        <button class="btn btn-secondary" onclick="clearFileList()">
                                            🗑️ 清空列表
                                        </button>
                                    </div>
                                </div>
                                <!-- 文件预览列表 -->
                                <div id="files-preview"></div>
                            </div>
                            
                            <!-- 上传进度 -->
                            <div id="upload-progress" style="margin-top: 15px; display: none;">
                                <div class="progress-bar">
                                    <div class="progress-fill" id="progress-fill"></div>
                                </div>
                                <div id="progress-text">上传中...</div>
                            </div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section">
                    <summary>🗑️ 删除歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <input type="text" class="form-control" id="delete-song-name" placeholder="输入歌曲名称..." style="margin-bottom: 10px;">
                            <button class="btn btn-danger" onclick="deleteSongByName()">删除歌曲</button>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section" open>
                    <summary>🎵 歌曲列表</summary>
                    <div class="collapsible-content">
                        <div class="search-box">
                            <span class="search-icon">🔍</span>
                            <input type="text" class="form-control" id="song-search" placeholder="搜索歌曲..." oninput="searchSongs()">
                        </div>
                        <div id="songs-list" class="song-list">
                            <div class="loading">正在加载歌曲...</div>
                        </div>
                    </div>
                </details>
            </div>

            <div id="tools" class="tab-content">
                <details class="collapsible-section">
                    <summary>🔄 批量重命名</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #6c757d; margin-bottom: 15px;">将所有文件重命名为播放器友好的格式（课程名-A.mp3, 课程名-B.mp3...）</p>
                            <button class="btn btn-secondary" onclick="batchRename()">执行批量重命名</button>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section">
                    <summary>📁 一键还原</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #6c757d; margin-bottom: 15px;">将所有音乐文件复制到 music 文件夹，并还原为原始文件名</p>
                            <button class="btn btn-primary" onclick="restoreMusic()">一键还原到 music 文件夹</button>
                            <div id="restore-result" style="margin-top: 15px;"></div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section" open>
                    <summary>🔍 查询歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <input type="text" class="form-control" id="query-song" placeholder="输入歌曲名称..." style="margin-bottom: 10px;">
                            <button class="btn btn-primary" onclick="querySong()">查询</button>
                            <div id="query-result" style="margin-top: 15px;"></div>
                        </div>
                    </div>
                </details>
            </div>
        </div>
    </div>
    <script>
        let allData = {};
        let allSongs = [];
        let selectedFiles = [];
        
        function showTab(tabName) {
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.getElementById(tabName).classList.add('active');
            event.target.classList.add('active');
            if (tabName === 'overview') loadOverview();
            if (tabName === 'courses') loadCourses();
            if (tabName === 'songs') loadSongs();
        }
        
        // 拖拽上传功能
        let dragDropInitialized = false;
        function initDragDrop() {
            if (dragDropInitialized) return;
            
            const dropZone = document.getElementById('drop-zone');
            const fileInput = document.getElementById('song-files');
            
            if (!dropZone || !fileInput) return;
            
            // 拖拽事件
            dropZone.addEventListener('dragover', (e) => {
                e.preventDefault();
                dropZone.classList.add('dragover');
            });
            
            dropZone.addEventListener('dragleave', (e) => {
                e.preventDefault();
                dropZone.classList.remove('dragover');
            });
            
            dropZone.addEventListener('drop', (e) => {
                e.preventDefault();
                dropZone.classList.remove('dragover');
                const files = Array.from(e.dataTransfer.files).filter(f => f.name.endsWith('.mp3'));
                addFilesToList(files);
            });
            
            // 点击选择文件
            dropZone.addEventListener('click', (e) => {
                // 防止按钮点击事件冒泡
                if (e.target.tagName === 'BUTTON') return;
                fileInput.click();
            });
            
            fileInput.addEventListener('change', (e) => {
                const files = Array.from(e.target.files);
                addFilesToList(files);
                // 立即清空输入框，防止重复触发
                setTimeout(() => {
                    e.target.value = '';
                }, 100);
            });
            
            dragDropInitialized = true;
        }
        
        function addFilesToList(files) {
            console.log('添加文件到列表:', files.map(f => f.name));
            console.log('当前已选文件:', selectedFiles.map(f => f.name));
            
            // 避免重复添加相同的文件
            const newFiles = files.filter(newFile => 
                !selectedFiles.some(existingFile => 
                    existingFile.name === newFile.name && 
                    existingFile.size === newFile.size &&
                    existingFile.lastModified === newFile.lastModified
                )
            );
            
            console.log('过滤后的新文件:', newFiles.map(f => f.name));
            
            selectedFiles = [...selectedFiles, ...newFiles];
            updateFileList();
        }
        
        function updateFileList() {
            const fileList = document.getElementById('file-list');
            const preview = document.getElementById('files-preview');
            
            if (selectedFiles.length === 0) {
                fileList.style.display = 'none';
                return;
            }
            
            fileList.style.display = 'block';
            preview.innerHTML = selectedFiles.map((file, index) => \`
                <div class="file-item">
                    <div class="file-info">
                        <div class="file-name">\${file.name}</div>
                        <div class="file-size">\${(file.size / 1024 / 1024).toFixed(2)} MB</div>
                    </div>
                    <button class="btn btn-danger" onclick="removeFile(\${index})">删除</button>
                </div>
            \`).join('');
        }
        
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            updateFileList();
        }
        
        function clearFileList() {
            selectedFiles = [];
            updateFileList();
            const fileInput = document.getElementById('song-files');
            if (fileInput) fileInput.value = '';
        }
        
        async function uploadBatchFiles() {
            if (selectedFiles.length === 0) {
                alert('请先选择文件');
                return;
            }
            
            const course = document.getElementById('course-select').value;
            
            // 显示进度条
            const progressDiv = document.getElementById('upload-progress');
            const progressFill = document.getElementById('progress-fill');
            const progressText = document.getElementById('progress-text');
            
            progressDiv.style.display = 'block';
            progressFill.style.width = '0%';
            progressText.textContent = '准备上传...';
            
            const BATCH_SIZE = 20; // 每批20个文件
            const totalFiles = selectedFiles.length;
            const batches = [];
            
            // 分批处理文件
            for (let i = 0; i < totalFiles; i += BATCH_SIZE) {
                batches.push(selectedFiles.slice(i, i + BATCH_SIZE));
            }
            
            const allResults = [];
            const allErrors = [];
            
            try {
                for (let batchIndex = 0; batchIndex < batches.length; batchIndex++) {
                    const batch = batches[batchIndex];
                    const startIndex = batchIndex * BATCH_SIZE;
                    
                    progressText.textContent = '上传第 ' + (batchIndex + 1) + '/' + batches.length + ' 批...';
                    
                    const formData = new FormData();
                    if (course) formData.append('course', course);
                    
                    batch.forEach(file => {
                        formData.append('songs', file);
                    });
                    
                    const response = await fetch('/api/add-songs-batch', {
                        method: 'POST',
                        body: formData
                    });
                    
                    const result = await response.json();
                    
                    if (response.ok) {
                        allResults.push(...(result.success || []));
                        allErrors.push(...(result.errors || []));
                    } else {
                        // 如果整个批次失败，将所有文件标记为失败
                        batch.forEach(file => {
                            allErrors.push({
                                file: file.name,
                                error: result.error || '上传失败'
                            });
                        });
                    }
                    
                    // 更新进度
                    const progress = ((batchIndex + 1) / batches.length) * 100;
                    progressFill.style.width = progress + '%';
                }
                
                // 显示最终结果
                progressText.textContent = '上传完成：成功 ' + allResults.length + ' 个，失败 ' + allErrors.length + ' 个';
                
                const successMessage = '批量上传完成：成功 ' + allResults.length + ' 个，失败 ' + allErrors.length + ' 个';
                showAlert(successMessage, allErrors.length === 0 ? 'success' : 'warning');
                
                // 显示错误详情
                if (allErrors.length > 0) {
                    allErrors.forEach(err => {
                        showAlert(err.file + ': ' + err.error, 'error');
                    });
                }
                
                clearFileList();
                loadSongs();
                loadCourses();
                
            } catch (error) {
                progressText.textContent = '上传失败';
                showAlert('批量上传失败: ' + error.message, 'error');
            }
            
            setTimeout(() => {
                progressDiv.style.display = 'none';
            }, 5000); // 延长显示时间
        }
        async function loadOverview() {
            try {
                const [statsRes, songsRes] = await Promise.all([fetch('/api/stats'), fetch('/api/songs')]);
                const [stats, songs] = await Promise.all([statsRes.json(), songsRes.json()]);
                document.getElementById('stats-grid').innerHTML = \`
                    <div class="stat-card" onclick="showTab('courses'); document.querySelector('button[onclick*=courses]').click();">
                        <div class="stat-number">\${stats.total_courses}</div>
                        <div class="stat-label">总课程数</div>
                    </div>
                    <div class="stat-card" onclick="showTab('songs'); document.querySelector('button[onclick*=songs]').click();">
                        <div class="stat-number">\${stats.total_songs}</div>
                        <div class="stat-label">总歌曲数</div>
                    </div>
                    <div class="stat-card" onclick="showTab('courses'); document.querySelector('button[onclick*=courses]').click();">
                        <div class="stat-number">\${stats.courses_with_songs}</div>
                        <div class="stat-label">有歌曲的课程</div>
                    </div>
                    <div class="stat-card" onclick="showTab('songs'); document.querySelector('button[onclick*=songs]').click();">
                        <div class="stat-number">\${stats.empty_slots}</div>
                        <div class="stat-label">空闲位置</div>
                    </div>\`;
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
            const courses = Object.entries(data).sort(([a],[b]) => a.localeCompare(b));
            
            // 分类课程
            const fullCourses = [];
            const partialCourses = [];
            const emptyCourses = [];
            
            courses.forEach(([course, info]) => {
                const songs = info.songs || [];
                const songCount = songs.filter(s => s !== null).length;
                
                if (songCount === 2) {
                    fullCourses.push([course, info]);
                } else if (songCount === 1) {
                    partialCourses.push([course, info]);
                } else {
                    emptyCourses.push([course, info]);
                }
            });
            
            // 渲染各类课程
            renderCourseCategory('courses-full', fullCourses);
            renderCourseCategory('courses-partial', partialCourses);
            renderCourseCategory('courses-empty', emptyCourses);
        }
        
        function renderCourseCategory(containerId, courses) {
            const container = document.getElementById(containerId);
            if (!container) return;
            
            if (courses.length === 0) {
                container.innerHTML = '<div class="empty-slot">暂无课程</div>';
                return;
            }
            
            container.innerHTML = courses.map(([course, info]) => {
                const dateMatch = course.match(/(\\d{4})(\\d{2})(\\d{2})/);
                const dateStr = dateMatch ? \`\${dateMatch[1]}-\${dateMatch[2]}-\${dateMatch[3]}\` : course;
                
                // 课程信息 - 一行显示
                const courseMeta = info.course_metadata;
                const fileName = course.replace('.mp3', '');
                const courseInfoHtml = courseMeta ? \`
                    <div class="course-info">
                        <div class="course-title-info">📚 \${courseMeta.title}</div>
                        <div class="course-meta-info">📁 \${fileName} | 🎤 \${courseMeta.artist} | ⏱️ \${courseMeta.duration ? Math.floor(courseMeta.duration / 60) + ':' + (courseMeta.duration % 60).toString().padStart(2, '0') : '未知'}</div>
                        <button class="btn btn-primary course-play-btn" onclick="playAudio('/songs/\${course}')">▶️ 播放</button>
                    </div>
                \` : \`
                    <div class="course-info">
                        <div class="course-title-info">📁 \${fileName}</div>
                        <div class="course-meta-info">📅 \${dateStr}</div>
                        <button class="btn btn-primary course-play-btn" onclick="playAudio('/songs/\${course}')">▶️ 播放</button>
                    </div>
                \`;
                
                // 歌曲信息
                const songsHtml = info.songs.map((song, i) => {
                    if (song) {
                        const fileInfo = info.renamed_files.find(f => f.slot === i);
                        const meta = info.songs_metadata[i];
                        const songFileName = song.replace('.mp3', '');
                        const friendlyName = fileInfo ? fileInfo.friendly_name : songFileName;
                        return \`
                            <div class="song-slot">
                                <div class="song-info">
                                    <div class="song-title">🎵 \${friendlyName} | 📁 \${songFileName} | 🎤 \${meta?.artist || '未知'} | 📅 \${meta?.year || '未知'}</div>
                                </div>
                                <div style="margin-left: 15px;">
                                    <button class="btn btn-primary" onclick="playAudio('/songs/\${song}')">▶️ 播放</button>
                                    <button class="btn btn-danger" onclick="removeSong('\${course}',\${i})">删除</button>
                                </div>
                            </div>
                        \`;
                    }
                    return '';
                }).join('');
                
                // 空位 - 放在一行
                const emptySlots = [];
                info.songs.forEach((song, i) => {
                    if (!song) {
                        emptySlots.push(\`
                            <div class="empty-slot-upload" ondrop="dropToSlot(event, '\${course}', \${i})" ondragover="allowDrop(event)" ondragleave="removeDragover(event)" onclick="uploadToSlot('\${course}', \${i})">
                                <div class="upload-icon">📁</div>
                                <div class="upload-text">
                                    <strong>空位 \${i + 1}</strong><br>
                                    点击或拖拽上传
                                </div>
                            </div>
                        \`);
                    }
                });
                
                const emptySlotsHtml = emptySlots.length > 0 ? \`
                    <div class="empty-slots-row">
                        \${emptySlots.join('')}
                    </div>
                \` : '';
                
                return \`
                    <div class="course-card">
                        <div class="course-body">
                            \${courseInfoHtml}
                            \${songsHtml}
                            \${emptySlotsHtml}
                        </div>
                    </div>
                \`;
            }).join('');
        }
        
        function searchCourses() {
            const query = document.getElementById('course-search').value.toLowerCase();
            if (!query) {
                displayCourses(allData);
                return;
            }
            
            const filtered = {};
            for (const [course, info] of Object.entries(allData)) {
                const courseMeta = info.course_metadata || {};
                const matchCourse = course.toLowerCase().includes(query) ||
                                  (courseMeta.title && courseMeta.title.toLowerCase().includes(query)) ||
                                  (courseMeta.year && courseMeta.year.toString().includes(query)) ||
                                  (courseMeta.artist && courseMeta.artist.toLowerCase().includes(query));
                
                const matchSongs = info.renamed_files && info.renamed_files.some(f => 
                    f.friendly_name.toLowerCase().includes(query) ||
                    f.metadata.title.toLowerCase().includes(query) ||
                    f.metadata.artist.toLowerCase().includes(query) ||
                    f.metadata.year.toString().includes(query)
                );
                
                if (matchCourse || matchSongs) {
                    filtered[course] = info;
                }
            }
            displayCourses(filtered);
        }
        
        // 内嵌播放器功能
        async function playAudio(src, songInfo = null) {
            // 移除现有的播放器
            const existingPlayer = document.getElementById('audio-player');
            if (existingPlayer) {
                existingPlayer.remove();
            }
            
            // 获取歌曲信息
            let songData = songInfo;
            if (!songData) {
                // 从已加载的数据中查找歌曲信息
                const fileName = src.split('/').pop();
                for (const [course, info] of Object.entries(allData)) {
                    const fileRecord = info.renamed_files?.find(f => f.playlist_name === fileName);
                    if (fileRecord) {
                        songData = fileRecord;
                        break;
                    }
                    // 检查是否是课程文件
                    if (course === fileName) {
                        songData = {
                            friendly_name: info.course_metadata?.title || fileName.replace('.mp3', ''),
                            metadata: info.course_metadata || {}
                        };
                        break;
                    }
                }
            }
            
            // 创建新的播放器
            const player = document.createElement('div');
            player.id = 'audio-player';
            player.style.cssText = 'position: fixed; bottom: 20px; right: 20px; background: white; padding: 20px; border-radius: 15px; box-shadow: 0 15px 40px rgba(0,0,0,0.3); z-index: 10000; min-width: 350px; max-width: 400px;';
            
            const songTitle = songData?.friendly_name || src.split('/').pop().replace('.mp3', '');
            const artist = songData?.metadata?.artist || '未知艺术家';
            const album = songData?.metadata?.album || '未知专辑';
            const year = songData?.metadata?.year || '未知年份';
            const albumArt = songData?.metadata?.albumArt;
            
            // 生成封面图片HTML
            const fileName = src.split('/').pop();
            let albumArtHtml;
            
            // 根据文件类型和艺术家生成不同的默认封面
            const isCourseFie = fileName.match(/^\d{8}(-\d+)?\.mp3$/);
            let defaultIcon, defaultBg;
            
            if (isCourseFie) {
                defaultIcon = '📚';
                defaultBg = 'linear-gradient(135deg, #2196f3 0%, #21cbf3 100%)';
            } else if (artist.includes('薛兆丰')) {
                defaultIcon = '🎓';
                defaultBg = 'linear-gradient(135deg, #ff6b6b 0%, #feca57 100%)';
            } else {
                defaultIcon = '🎵';
                defaultBg = 'linear-gradient(135deg, #667eea 0%, #764ba2 100%)';
            }
            
            if (albumArt && albumArt.data) {
                albumArtHtml = \`<img src="data:\${albumArt.format};base64,\${albumArt.data}" style="width: 60px; height: 60px; border-radius: 8px; object-fit: cover; border: 2px solid #e9ecef;" alt="封面">\`;
            } else {
                // 尝试从API获取封面图片，失败则显示智能默认图标
                albumArtHtml = \`
                    <img src="/api/album-art/\${fileName}" 
                         style="width: 60px; height: 60px; border-radius: 8px; object-fit: cover; border: 2px solid #e9ecef;" 
                         alt="封面" 
                         onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';">
                    <div style="width: 60px; height: 60px; background: \${defaultBg}; border-radius: 8px; display: none; align-items: center; justify-content: center; border: 2px solid #e9ecef;">
                        <span style="font-size: 1.5rem; color: white;">\${defaultIcon}</span>
                    </div>
                \`;
            }
            
            player.innerHTML = \`
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 15px;">
                    <strong style="color: #495057;">🎵 正在播放</strong>
                    <button onclick="document.getElementById('audio-player').remove()" style="background: none; border: none; font-size: 1.2rem; cursor: pointer; color: #6c757d;">✕</button>
                </div>
                
                <div style="display: flex; align-items: center; margin-bottom: 15px;">
                    <div style="margin-right: 15px;">
                        \${albumArtHtml}
                    </div>
                    <div style="flex: 1;">
                        <div style="font-weight: 600; color: #495057; margin-bottom: 3px; font-size: 1rem;">\${songTitle}</div>
                        <div style="font-size: 0.85rem; color: #6c757d;">🎤 \${artist}</div>
                        <div style="font-size: 0.8rem; color: #adb5bd;">💿 \${album} | 📅 \${year}</div>
                    </div>
                </div>
                
                <audio controls autoplay style="width: 100%; margin-bottom: 10px;">
                    <source src="\${src}" type="audio/mpeg">
                    您的浏览器不支持音频播放
                </audio>
                
                <div style="font-size: 0.8rem; color: #adb5bd; text-align: center;">
                    📁 \${src.split('/').pop()}
                </div>
            \`;
            
            document.body.appendChild(player);
        }
        
        // 拖拽到空位的处理函数
        function allowDrop(event) {
            event.preventDefault();
            event.target.closest('.empty-slot-upload').classList.add('dragover');
        }
        
        function removeDragover(event) {
            event.target.closest('.empty-slot-upload').classList.remove('dragover');
        }
        
        function dropToSlot(event, course, slot) {
            event.preventDefault();
            event.target.closest('.empty-slot-upload').classList.remove('dragover');
            
            const files = Array.from(event.dataTransfer.files).filter(f => f.name.endsWith('.mp3'));
            if (files.length === 0) {
                alert('请拖拽 MP3 文件');
                return;
            }
            
            if (files.length > 1) {
                alert('每次只能上传一个文件到指定位置');
                return;
            }
            
            uploadFileToSlot(files[0], course, slot);
        }
        
        function uploadToSlot(course, slot) {
            const input = document.createElement('input');
            input.type = 'file';
            input.accept = '.mp3';
            input.onchange = (e) => {
                if (e.target.files[0]) {
                    uploadFileToSlot(e.target.files[0], course, slot);
                }
            };
            input.click();
        }
        
        async function uploadFileToSlot(file, course, slot) {
            // 直接使用文件名作为友好名称，不再弹出提示框
            const friendlyName = file.name.replace('.mp3', '');
            
            const formData = new FormData();
            formData.append('course', course);
            formData.append('slot', slot);
            formData.append('song', file);
            if (friendlyName) formData.append('friendly_name', friendlyName);
            
            try {
                const response = await fetch('/api/add-song-to-slot', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                if (response.ok) {
                    showAlert(\`歌曲已添加到 \${course} 位置 \${parseInt(slot) + 1}: \${result.friendly_name}\`, 'success');
                    loadCourses();
                } else {
                    showAlert('上传失败: ' + result.error, 'error');
                }
            } catch (error) {
                showAlert('上传失败: ' + error.message, 'error');
            }
        }
        async function loadSongs() {
            try {
                const [songsRes, dataRes] = await Promise.all([fetch('/api/songs'), fetch('/api/list')]);
                const [songs, data] = await Promise.all([songsRes.json(), dataRes.json()]);
                allSongs = songs;
                document.getElementById('course-select').innerHTML = '<option value="">自动分配到有空位的课程</option>' + Object.keys(data).sort().map(c => \`<option value="\${c}">\${c}</option>\`).join('');
                displaySongs(allSongs);
                initDragDrop(); // 初始化拖拽功能
            } catch (e) { console.error('加载失败:', e); }
        }
        function displaySongs(songs) {
            const songsList = document.getElementById('songs-list');
            if (songs.length === 0) {
                songsList.innerHTML = '<div class="empty-slot">暂无歌曲</div>';
                return;
            }
            
            songsList.innerHTML = songs.map(s => \`
                <div class="song-item" style="display: flex; align-items: center; justify-content: space-between;">
                    <div style="flex: 1;">
                        <div class="song-title">\${s.friendly_name}</div>
                        <div class="song-meta">📁 \${s.playlist_name.replace('.mp3', '')} | 🎤 \${s.metadata.artist} | 📅 \${s.metadata.year} | 📚 \${s.course.replace('.mp3', '')}</div>
                    </div>
                    <button class="btn btn-primary" onclick="playAudio('/songs/\${s.playlist_name}', \${JSON.stringify(s).replace(/"/g, '&quot;')})">▶️ 播放</button>
                </div>
            \`).join('');
        }
        function searchSongs() {
            const q = document.getElementById('song-search').value.toLowerCase();
            displaySongs(allSongs.filter(s => s.friendly_name.toLowerCase().includes(q) || s.metadata.artist.toLowerCase().includes(q) || s.course.toLowerCase().includes(q)));
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
        
        async function restoreMusic() {
            if (!confirm('确定要将所有音乐文件还原到 music 文件夹吗？这会复制所有文件并还原原始名称。')) return;
            
            try {
                const response = await fetch('/api/restore-music', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'}
                });
                
                const result = await response.json();
                const resultDiv = document.getElementById('restore-result');
                
                if (response.ok) {
                    resultDiv.innerHTML = \`
                        <div class="alert alert-success">
                            <strong>\${result.message}</strong><br>
                            还原文件夹: \${result.music_folder}<br>
                            成功文件: \${result.restored.length} 个<br>
                            失败文件: \${result.errors.length} 个
                        </div>
                    \`;
                    
                    if (result.errors.length > 0) {
                        console.log('还原错误:', result.errors);
                        result.errors.forEach(err => {
                            showAlert(\`\${err.file}: \${err.error}\`, 'error');
                        });
                    }
                } else {
                    resultDiv.innerHTML = '<div class="alert alert-error">还原失败: ' + result.error + '</div>';
                }
            } catch (error) {
                document.getElementById('restore-result').innerHTML = '<div class="alert alert-error">还原失败: ' + error.message + '</div>';
            }
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
    </script>
</body>
</html>`;
}

// ------------------- 启动 -------------------
app.listen(PORT, () => {
    console.log(`Server running at http://localhost:${PORT}`);
});
