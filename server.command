#!/usr/bin/env node

process.env.NODE_PATH = require('child_process')
    .execSync('npm root -g')
    .toString().trim();

require('module').Module._initPaths(); // 刷新 module 查找路径

// ================= 依赖导入 =================
const express = require('express');
const fs = require('fs');
const path = require('path');
const mm = require('music-metadata');
const multer = require('multer');

// ================= 常量配置 =================
const PORT = 3000;
const SONG_DIR = __dirname;
const DATA_FILE = path.join(__dirname, 'music-map.json');

// Security: Input validation and sanitization
function sanitizeInput(input) {
    if (typeof input !== 'string') return input;
    return input.replace(/[<>\"'&]/g, function(match) {
        const escapeMap = {
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;',
            "'": '&#x27;',
            '&': '&amp;'
        };
        return escapeMap[match];
    });
}

function validateFilename(filename) {
    if (!filename || typeof filename !== 'string') return false;
    if (filename.includes('..') || filename.includes('/') || filename.includes('\\')) return false;
    if (filename.length > 255) return false;
    return true;
}

// Simple rate limiting implementation
const rateLimiter = {
    requests: new Map(),

    isAllowed(ip, endpoint, maxRequests = 100, windowMs = 60000) {
        const key = `${ip}:${endpoint}`;
        const now = Date.now();
        const windowStart = now - windowMs;

        if (!this.requests.has(key)) {
            this.requests.set(key, []);
        }

        const requests = this.requests.get(key);
        // Clean old requests
        const validRequests = requests.filter(time => time > windowStart);

        if (validRequests.length >= maxRequests) {
            return false;
        }

        validRequests.push(now);
        this.requests.set(key, validRequests);

        // Cleanup old entries periodically
        if (Math.random() < 0.01) { // 1% chance
            this.cleanup();
        }

        return true;
    },

    cleanup() {
        const now = Date.now();
        for (const [key, requests] of this.requests.entries()) {
            const validRequests = requests.filter(time => time > now - 300000); // 5 minutes
            if (validRequests.length === 0) {
                this.requests.delete(key);
            } else {
                this.requests.set(key, validRequests);
            }
        }
    }
};

// Rate limiting middleware
function rateLimit(endpoint, maxRequests = 100, windowMs = 60000) {
    return (req, res, next) => {
        const clientIP = req.ip || req.connection.remoteAddress || 'unknown';

        if (!rateLimiter.isAllowed(clientIP, endpoint, maxRequests, windowMs)) {
            return res.status(429).json({
                error: 'Too many requests. Please try again later.',
                retryAfter: Math.ceil(windowMs / 1000)
            });
        }

        next();
    };
}

// ================= 应用配置 =================
const app = express();

// 调试开关
const DEBUG = process.env.DEBUG || false ; // 设置为 true 启用详细日志

// 设置console.debug的行为
if (!DEBUG) {
    console.debug = function() {}; // DEBUG模式关闭时，console.debug不输出任何内容
}

app.use(express.json());
app.use(express.urlencoded({extended: true}));

// Security: Disable X-Powered-By header
app.disable('x-powered-by');

// Security: Add security headers
app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('X-XSS-Protection', '1; mode=block');
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    next();
});

// Cache control for API endpoints
app.use('/api', (req, res, next) => {
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    next();
});

app.use('/songs', express.static(SONG_DIR)); // 静态访问歌曲

// 文件上传配置
const upload = multer({
    dest: SONG_DIR,
    limits: {
        fileSize: 50 * 1024 * 1024, // 50MB limit
        files: 1
    },
    fileFilter: (req, file, cb) => {
        // Security: Only allow MP3 files
        if (file.mimetype !== 'audio/mpeg' && file.mimetype !== 'audio/mp3') {
            return cb(new Error('Only MP3 files are allowed'), false);
        }

        // Security: Validate file extension
        if (!file.originalname.toLowerCase().endsWith('.mp3')) {
            return cb(new Error('Only .mp3 files are allowed'), false);
        }

        // Security: Sanitize filename - remove path separators and dangerous characters
        const sanitizedName = file.originalname.replace(/[\/\\:*?"<>|]/g, '_');
        file.originalname = Buffer.from(sanitizedName, 'latin1').toString('utf8');

        // Security: Check filename length
        if (file.originalname.length > 255) {
            return cb(new Error('Filename too long'), false);
        }

        cb(null, true);
    }
});
const uploadMultiple = multer({
    dest: SONG_DIR,
    limits: {
        fileSize: 50 * 1024 * 1024, // 50MB per file limit
        files: 20 // Reduced from 100 to 20 for security
    },
    fileFilter: (req, file, cb) => {
        // Security: Only allow MP3 files
        if (file.mimetype !== 'audio/mpeg' && file.mimetype !== 'audio/mp3') {
            return cb(new Error('Only MP3 files are allowed'), false);
        }

        // Security: Validate file extension
        if (!file.originalname.toLowerCase().endsWith('.mp3')) {
            return cb(new Error('Only .mp3 files are allowed'), false);
        }

        // Security: Sanitize filename - remove path separators and dangerous characters
        const sanitizedName = file.originalname.replace(/[\/\\:*?"<>|]/g, '_');
        file.originalname = Buffer.from(sanitizedName, 'latin1').toString('utf8');

        // Security: Check filename length
        if (file.originalname.length > 255) {
            return cb(new Error('Filename too long'), false);
        }

        cb(null, true);
    }
}).array('songs', 20); // Support max 20 files for batch processing

// ------------------- 数据操作 -------------------
function initData() {
    if (!fs.existsSync(DATA_FILE)) {
        console.log('数据文件不存在，创建新的 music-map.json');
        fs.writeFileSync(DATA_FILE, JSON.stringify({}, null, 2));
    }
    let data;
    try {
        const fileContent = fs.readFileSync(DATA_FILE, 'utf-8');
        data = JSON.parse(fileContent);

        // 验证数据文件结构的完整性
        if (!data || typeof data !== 'object') {
            throw new Error('数据文件结构无效');
        }

        console.log(`数据文件加载成功，包含 ${Object.keys(data).length} 个课程`);
    } catch (e) {
        console.error('数据文件格式错误，重新初始化:', e.message);
        // 备份损坏的文件
        if (fs.existsSync(DATA_FILE)) {
            const backupFile = DATA_FILE + '.backup.' + Date.now();
            fs.copyFileSync(DATA_FILE, backupFile);
            console.log(`损坏的数据文件已备份到: ${backupFile}`);
        }
        data = {};
    }

    // 扫描当前目录 mp3 文件
    const files = fs.readdirSync(__dirname).filter(f => f.endsWith('.mp3'));
    let hasChanges = false;

    // 课程音频文件格式: 20170221-2.mp3 20170316.mp3   20170411.mp3   20170504.mp3
    // 音乐格式：使用数字序号以确保播放器正确排序：001-课程.mp3, 002-歌曲1.mp3, 003-歌曲2.mp3
    files.forEach(file => {
        // 匹配课程文件名：8位数字开头 + 可选 -数字
        if (/^\d{8}(-\d+)?\.mp3$/.test(file)) {
            if (!data[file]) {
                console.log(`发现新课程文件: ${file}`);
                data[file] = {
                    songs: [null, null], // 两首歌曲位置
                    metadata: null,      // 课程元数据
                    renamed_files: []    // 重命名后的文件列表
                };
                hasChanges = true;
            } else if (Array.isArray(data[file])) {
                // 兼容旧数据格式：[song1, song2] -> {songs: [song1, song2], ...}
                console.log(`升级旧数据格式: ${file}`);
                const oldSongs = data[file];
                data[file] = {
                    songs: oldSongs,
                    metadata: null,
                    renamed_files: []
                };
                hasChanges = true;
            }
        }
    });

    // 清理不存在的文件引用
    for (const [course, info] of Object.entries(data)) {
        if (info.renamed_files) {
            const originalLength = info.renamed_files.length;
            info.renamed_files = info.renamed_files.filter(file => {
                const filePath = path.join(__dirname, file.playlist_name);
                const exists = fs.existsSync(filePath);
                if (!exists) {
                    console.log(`清理不存在的文件引用: ${file.playlist_name}`);
                }
                return exists;
            });
            if (info.renamed_files.length !== originalLength) {
                hasChanges = true;
            }
        }
    }

    // 只有在有变化时才保存数据
    if (hasChanges) {
        console.log('检测到数据变化，保存更新');
        saveData(data);
    } else {
        console.log('数据文件无变化，跳过保存');
    }

    return data;
}

function loadData() {
    return initData(); // initData now returns the data directly
}

function saveData(data) {
    try {
        // 创建一个深拷贝，避免修改原始数据，同时移除albumArt数据以减小文件大小
        const dataToSave = JSON.parse(JSON.stringify(data, (key, value) => {
            // 不再保存albumArt数据到JSON文件中，图片通过API动态加载
            if (key === 'albumArt') {
                return undefined; // 完全移除albumArt字段
            }
            return value;
        }));

        fs.writeFileSync(DATA_FILE, JSON.stringify(dataToSave, null, 2));
    } catch (error) {
        console.error('保存数据失败:', error);
        // 如果保存失败，尝试保存一个最小的有效JSON
        fs.writeFileSync(DATA_FILE + '.error', JSON.stringify(data, null, 2));
        throw error;
    }
}

// 获取音乐元数据（包括封面图片）
async function getMusicMetadata(filePath) {
    console.debug(`\n=== 开始解析文件: ${filePath} ===`);

    try {
        const metadata = await mm.parseFile(filePath, {
            skipCovers: false,
            skipPostHeaders: false,
            includeChapters: false
        });

        console.debug('原始元数据结构:', {
            hasCommon: !!metadata.common,
            hasFormat: !!metadata.format,
            commonKeys: metadata.common ? Object.keys(metadata.common) : [],
            formatKeys: metadata.format ? Object.keys(metadata.format) : []
        });

        if (metadata.common) {
            console.debug('Common字段详情:', {
                title: metadata.common.title,
                artist: metadata.common.artist,
                album: metadata.common.album,
                year: metadata.common.year,
                genre: metadata.common.genre,
                pictureCount: metadata.common.picture ? metadata.common.picture.length : 0
            });
        }

        let hasAlbumArt = false;

        // 检查是否有封面图片（不存储数据，只记录是否存在）
        if (metadata.common && metadata.common.picture && metadata.common.picture.length > 0) {
            try {
                const picture = metadata.common.picture[0];
                if (picture.data && picture.format) {
                    hasAlbumArt = true;
                    console.debug('检测到封面图片:', {
                        format: picture.format,
                        hasData: !!picture.data
                    });
                }
            } catch (pictureError) {
                console.debug(`封面检测失败 ${filePath}:`, pictureError.message);
                console.warn(`封面检测失败 ${filePath}:`, pictureError.message);
            }
        } else {
            console.debug('文件中没有找到封面图片');
        }

        const result = {
            title: metadata.common?.title || path.basename(filePath, '.mp3'),
            artist: metadata.common?.artist || '未知艺术家',
            album: metadata.common?.album || '未知专辑',
            year: metadata.common?.year || '未知年份',
            genre: metadata.common?.genre ? metadata.common.genre.join(', ') : '未知流派',
            duration: metadata.format?.duration ? Math.round(metadata.format.duration) : 0,
            hasAlbumArt: hasAlbumArt
        };

        console.debug('最终提取结果:', {
            title: result.title,
            artist: result.artist,
            album: result.album,
            year: result.year,
            genre: result.genre,
            duration: result.duration,
            hasAlbumArt: result.hasAlbumArt,
            file: path.basename(filePath)
        });

        return result;
    } catch (error) {
        console.debug(`元数据提取完全失败 ${filePath}:`, error.message, error);
        console.warn(`元数据提取失败 ${filePath}:`, error.message);
        return {
            title: path.basename(filePath, '.mp3'),
            artist: '未知艺术家',
            album: '未知专辑',
            year: '未知年份',
            genre: '未知流派',
            duration: 0,
            hasAlbumArt: false
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

// 优化的分配算法：公平分配策略
function findAvailableCourseFair(data, strategy = 'round_robin') {
    const courses = Object.keys(data).sort();

    switch (strategy) {
        case 'round_robin':
            return findAvailableCourseRoundRobin(data, courses);
        case 'least_songs_first':
            return findAvailableCourseLeastSongsFirst(data, courses);
        case 'random':
            return findAvailableCourseRandom(data, courses);
        default:
            return findAvailableCourse(data); // 回退到原始算法
    }
}

// 轮询分配：优先给歌曲数量最少的课程分配
function findAvailableCourseRoundRobin(data, courses) {
    // 计算每个课程的歌曲数量
    const courseStats = courses.map(course => {
        const songs = data[course].songs || [];
        const songCount = songs.filter(song => song !== null).length;
        const emptySlots = songs.map((song, index) => song === null ? index : null).filter(slot => slot !== null);

        return {
            course,
            songCount,
            emptySlots,
            hasEmptySlot: emptySlots.length > 0
        };
    }).filter(stat => stat.hasEmptySlot);

    if (courseStats.length === 0) return null;

    // 按歌曲数量排序，优先分配给歌曲少的课程
    courseStats.sort((a, b) => a.songCount - b.songCount);

    const selected = courseStats[0];
    return {
        course: selected.course,
        slot: selected.emptySlots[0]
    };
}

// 最少歌曲优先：总是选择歌曲数量最少的课程
function findAvailableCourseLeastSongsFirst(data, courses) {
    let minSongs = Infinity;
    let selectedCourse = null;
    let selectedSlot = null;

    for (const course of courses) {
        const songs = data[course].songs || [];
        const songCount = songs.filter(song => song !== null).length;
        const emptyIndex = songs.indexOf(null);

        if (emptyIndex !== -1 && songCount < minSongs) {
            minSongs = songCount;
            selectedCourse = course;
            selectedSlot = emptyIndex;
        }
    }

    return selectedCourse ? { course: selectedCourse, slot: selectedSlot } : null;
}

// 随机分配：从有空位的课程中随机选择
function findAvailableCourseRandom(data, courses) {
    const availableCourses = [];

    for (const course of courses) {
        const songs = data[course].songs || [];
        const emptyIndex = songs.indexOf(null);
        if (emptyIndex !== -1) {
            availableCourses.push({ course, slot: emptyIndex });
        }
    }

    if (availableCourses.length === 0) return null;

    const randomIndex = Math.floor(Math.random() * availableCourses.length);
    return availableCourses[randomIndex];
}

// 批量分配算法：根据不同策略分配歌曲
function batchAllocation(data, songCount, strategy = 'round_robin') {
    const courses = Object.keys(data).sort();
    const allocations = [];

    // 创建数据副本以避免修改原始数据
    const dataCopy = JSON.parse(JSON.stringify(data));

    if (strategy === 'original') {
        // 真正的原始算法：按课程顺序依次填满
        return batchOriginalAllocation(dataCopy, songCount, courses);
    } else if (strategy === 'random') {
        // 纯随机分配：每次都随机选择
        return batchRandomAllocation(dataCopy, songCount, courses);
    } else {
        // 公平分配算法：先为每个课程分配一首，然后填充
        return batchFairAllocation(dataCopy, songCount, strategy, courses);
    }
}

// 原始算法：按课程顺序依次填满
function batchOriginalAllocation(dataCopy, songCount, courses) {
    const allocations = [];
    let songIndex = 0;

    for (const course of courses) {
        if (songIndex >= songCount) break;

        const songs = dataCopy[course].songs || [];
        for (let slot = 0; slot < songs.length; slot++) {
            if (songIndex >= songCount) break;
            if (songs[slot] === null) {
                allocations.push({ course, slot });
                dataCopy[course].songs[slot] = 'ALLOCATED';
                songIndex++;
            }
        }
    }

    return allocations;
}

// 纯随机分配：每次都随机选择有空位的课程
function batchRandomAllocation(dataCopy, songCount, courses) {
    const allocations = [];
    let songIndex = 0;

    while (songIndex < songCount) {
        const availableCourses = [];

        for (const course of courses) {
            const songs = dataCopy[course].songs || [];
            const emptyIndex = songs.indexOf(null);
            if (emptyIndex !== -1) {
                availableCourses.push({ course, slot: emptyIndex });
            }
        }

        if (availableCourses.length === 0) break;

        const randomIndex = Math.floor(Math.random() * availableCourses.length);
        const selected = availableCourses[randomIndex];

        allocations.push(selected);
        dataCopy[selected.course].songs[selected.slot] = 'ALLOCATED';
        songIndex++;
    }

    return allocations;
}

// 公平分配算法：先为每个课程分配一首，然后填充剩余位置
function batchFairAllocation(dataCopy, songCount, strategy, courses) {
    const allocations = [];

    // 第一阶段：为每个有空位的课程分配一首歌曲
    const coursesWithEmptySlots = courses.filter(course => {
        const songs = dataCopy[course].songs || [];
        return songs.includes(null);
    });

    // 按策略排序课程
    let sortedCourses;
    if (strategy === 'least_songs_first') {
        sortedCourses = coursesWithEmptySlots.sort((a, b) => {
            const songsA = (dataCopy[a].songs || []).filter(song => song !== null).length;
            const songsB = (dataCopy[b].songs || []).filter(song => song !== null).length;
            return songsA - songsB;
        });
    } else {
        // 默认轮询 - 按歌曲数量排序，确保公平分配
        sortedCourses = coursesWithEmptySlots.sort((a, b) => {
            const songsA = (dataCopy[a].songs || []).filter(song => song !== null).length;
            const songsB = (dataCopy[b].songs || []).filter(song => song !== null).length;
            return songsA - songsB;
        });
    }

    let songIndex = 0;

    // 第一轮：为每个课程分配一首歌曲（确保每个课程至少有一首）
    for (const course of sortedCourses) {
        if (songIndex >= songCount) break;

        const songs = dataCopy[course].songs || [];
        const emptySlot = songs.indexOf(null);
        if (emptySlot !== -1) {
            allocations.push({ course, slot: emptySlot });
            // 标记为已分配
            dataCopy[course].songs[emptySlot] = 'ALLOCATED';
            songIndex++;
        }
    }

    // 第二阶段：填充剩余位置，继续使用公平策略
    while (songIndex < songCount) {
        const available = findAvailableCourseFairWithCopy(dataCopy, strategy);
        if (!available) break;

        allocations.push(available);
        // 标记为已分配
        dataCopy[available.course].songs[available.slot] = 'ALLOCATED';
        songIndex++;
    }

    return allocations;
}

// 使用数据副本的公平分配函数
function findAvailableCourseFairWithCopy(dataCopy, strategy = 'round_robin') {
    const courses = Object.keys(dataCopy).sort();

    switch (strategy) {
        case 'round_robin':
            return findAvailableCourseRoundRobinWithCopy(dataCopy, courses);
        case 'least_songs_first':
            return findAvailableCourseLeastSongsFirstWithCopy(dataCopy, courses);
        case 'random':
            return findAvailableCourseRandomWithCopy(dataCopy, courses);
        default:
            return findAvailableCourseLeastSongsFirstWithCopy(dataCopy, courses);
    }
}

// 使用数据副本的轮询分配
function findAvailableCourseRoundRobinWithCopy(dataCopy, courses) {
    const courseStats = courses.map(course => {
        const songs = dataCopy[course].songs || [];
        const songCount = songs.filter(song => song !== null && song !== 'ALLOCATED').length;
        const emptySlots = songs.map((song, index) =>
            (song === null || song === 'ALLOCATED') ? null : index
        ).filter(slot => slot !== null);
        const actualEmptySlots = songs.map((song, index) =>
            song === null ? index : null
        ).filter(slot => slot !== null);

        return {
            course,
            songCount,
            emptySlots: actualEmptySlots,
            hasEmptySlot: actualEmptySlots.length > 0
        };
    }).filter(stat => stat.hasEmptySlot);

    if (courseStats.length === 0) return null;

    courseStats.sort((a, b) => a.songCount - b.songCount);

    const selected = courseStats[0];
    return {
        course: selected.course,
        slot: selected.emptySlots[0]
    };
}

// 使用数据副本的最少歌曲优先
function findAvailableCourseLeastSongsFirstWithCopy(dataCopy, courses) {
    let minSongs = Infinity;
    let selectedCourse = null;
    let selectedSlot = null;

    for (const course of courses) {
        const songs = dataCopy[course].songs || [];
        const songCount = songs.filter(song => song !== null && song !== 'ALLOCATED').length;
        const emptyIndex = songs.indexOf(null);

        if (emptyIndex !== -1 && songCount < minSongs) {
            minSongs = songCount;
            selectedCourse = course;
            selectedSlot = emptyIndex;
        }
    }

    return selectedCourse ? { course: selectedCourse, slot: selectedSlot } : null;
}

// 使用数据副本的随机分配
function findAvailableCourseRandomWithCopy(dataCopy, courses) {
    const availableCourses = [];

    for (const course of courses) {
        const songs = dataCopy[course].songs || [];
        const emptyIndex = songs.indexOf(null);
        if (emptyIndex !== -1) {
            availableCourses.push({ course, slot: emptyIndex });
        }
    }

    if (availableCourses.length === 0) return null;

    const randomIndex = Math.floor(Math.random() * availableCourses.length);
    return availableCourses[randomIndex];
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

// 后端策略显示名称映射
function getStrategyDisplayName(strategy) {
    const strategyNames = {
        'round_robin': '🔄 轮询分配',
        'least_songs_first': '⚖️ 最少歌曲优先',
        'random': '🎲 随机分配',
        'original': '📝 原始算法'
    };
    return strategyNames[strategy] || strategy;
}

// 分配算法性能分析
app.post('/api/analyze-allocation-performance', (req, res) => {
    try {
        const { songCount = 10 } = req.body;
        const data = loadData();
        const strategies = ['round_robin', 'least_songs_first', 'random'];

        const analysis = {
            songCount,
            strategies: {},
            recommendation: null
        };

        for (const strategy of strategies) {
            const allocations = batchAllocation(data, songCount, strategy);
            const stats = {};

            // 计算分配统计
            for (const allocation of allocations) {
                if (!stats[allocation.course]) stats[allocation.course] = 0;
                stats[allocation.course]++;
            }

            // 计算分配质量指标
            const courseCounts = Object.values(stats);
            const totalCourses = Object.keys(stats).length;
            const avgSongsPerCourse = songCount / totalCourses;
            const variance = courseCounts.reduce((sum, count) =>
                sum + Math.pow(count - avgSongsPerCourse, 2), 0) / totalCourses;
            const standardDeviation = Math.sqrt(variance);

            analysis.strategies[strategy] = {
                name: getStrategyDisplayName(strategy),
                allocatedCourses: totalCourses,
                allocationStats: stats,
                avgSongsPerCourse: avgSongsPerCourse.toFixed(2),
                standardDeviation: standardDeviation.toFixed(2),
                fairnessScore: (1 / (1 + standardDeviation)).toFixed(3) // 越接近1越公平
            };
        }

        // 推荐最佳策略（基于公平性得分）
        let bestStrategy = null;
        let bestScore = 0;
        for (const [strategy, info] of Object.entries(analysis.strategies)) {
            if (parseFloat(info.fairnessScore) > bestScore) {
                bestScore = parseFloat(info.fairnessScore);
                bestStrategy = strategy;
            }
        }

        analysis.recommendation = {
            strategy: bestStrategy,
            reason: `基于公平性得分 ${bestScore}，推荐使用 ${analysis.strategies[bestStrategy]?.name}`
        };

        res.json(analysis);

    } catch (error) {
        console.error('Allocation analysis error:', error);
        res.status(500).json({error: '分配分析失败: ' + error.message});
    }
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

// 批量公平分配预览 - 不实际分配，只返回分配计划
app.post('/api/preview-fair-allocation', (req, res) => {
    try {
        const { songCount, strategy = 'round_robin' } = req.body;

        if (!songCount || songCount <= 0) {
            return res.status(400).json({error: '歌曲数量必须大于0'});
        }

        const data = loadData();
        const allocations = batchAllocation(data, songCount, strategy);

        // 统计分配结果
        const allocationStats = {};
        for (const allocation of allocations) {
            if (!allocationStats[allocation.course]) {
                allocationStats[allocation.course] = 0;
            }
            allocationStats[allocation.course]++;
        }

        res.json({
            strategy,
            songCount,
            allocations,
            allocationStats,
            message: `使用${strategy}策略为${songCount}首歌曲生成分配计划`
        });

    } catch (error) {
        console.error('Fair allocation preview error:', error);
        res.status(500).json({error: '分配预览失败: ' + error.message});
    }
});

// 统一上传接口：支持单个文件上传到指定课程或自动分配
app.post('/api/upload-song', rateLimit('upload', 10, 60000), (req, res) => {
    upload.single('song')(req, res, async (err) => {
        if (err) {
            console.error('File upload error:', err.message);
            if (err instanceof multer.MulterError) {
                if (err.code === 'LIMIT_FILE_SIZE') {
                    return res.status(400).json({error: '文件太大，最大允许50MB'});
                }
                return res.status(400).json({error: '文件上传错误: ' + err.message});
            }
            return res.status(400).json({error: err.message});
        }

        const {course: targetCourse} = req.body;
        const file = req.file;
        if (!file) return res.status(400).json({error: '没有上传文件'});

        const data = loadData();

        // 确定目标课程和位置
        let assignedCourse = targetCourse;
        let index;

        if (!assignedCourse) {
            // 自动分配到有空位的课程 - 使用公平分配策略
            const available = findAvailableCourseFair(data, 'least_songs_first');
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
                // 指定课程满了，不自动分配，直接返回错误
                fs.unlinkSync(file.path);
                return res.status(400).json({error: `指定课程 ${assignedCourse} 已满，请选择其他课程或使用自动分配`});
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
            display_name: originalName.replace('.mp3', ''),
            auto_assigned: targetCourse !== assignedCourse
        });
    });
});

// 统一批量上传接口：支持不同分配策略
app.post('/api/upload-songs-batch', rateLimit('batch-upload', 20, 300000), (req, res) => {
    uploadMultiple(req, res, async (err) => {
        if (err) {
            console.error('Batch fair upload error:', err.message);
            if (err instanceof multer.MulterError) {
                if (err.code === 'LIMIT_FILE_SIZE') {
                    return res.status(400).json({error: '文件太大，最大允许50MB'});
                } else if (err.code === 'LIMIT_FILE_COUNT') {
                    return res.status(400).json({error: '文件数量太多，最多允许20个文件'});
                }
                return res.status(400).json({error: '文件上传错误: ' + err.message});
            }
            return res.status(400).json({error: err.message});
        }

        const { strategy = 'round_robin' } = req.body;
        const files = req.files;

        if (!files || files.length === 0) {
            return res.status(400).json({error: '没有上传文件'});
        }

        const data = loadData();
        const results = [];
        const errors = [];

        // 检查文件名重复
        for (const file of files) {
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
            }
        }

        // 过滤掉重复的文件
        const validFiles = files.filter(file =>
            !errors.some(error => error.file === file.originalname)
        );

        if (validFiles.length === 0) {
            return res.json({
                message: '批量公平分配完成：所有文件都有错误',
                success: [],
                errors: errors,
                total: files.length
            });
        }

        // 使用分配算法获取分配计划
        const allocations = batchAllocation(data, validFiles.length, strategy);

        if (allocations.length < validFiles.length) {
            // 清理多余的文件
            for (let i = allocations.length; i < validFiles.length; i++) {
                fs.unlinkSync(validFiles[i].path);
                errors.push({
                    file: validFiles[i].originalname,
                    error: '没有足够的空位进行分配'
                });
            }
        }

        // 执行分配
        for (let i = 0; i < Math.min(allocations.length, validFiles.length); i++) {
            const file = validFiles[i];
            const allocation = allocations[i];

            try {
                // 解析歌曲信息
                const metadata = await getMusicMetadata(file.path);

                // 生成播放器友好的文件名
                const newName = generatePlaylistName(allocation.course, allocation.slot);
                const newPath = path.join(SONG_DIR, newName);
                fs.renameSync(file.path, newPath);

                // 保存映射
                data[allocation.course].songs[allocation.slot] = newName;
                data[allocation.course].renamed_files = data[allocation.course].renamed_files || [];
                data[allocation.course].renamed_files.push({
                    original_name: file.originalname,
                    playlist_name: newName,
                    slot: allocation.slot,
                    metadata: metadata,
                    added_time: new Date().toISOString()
                });

                results.push({
                    original: file.originalname,
                    display_name: file.originalname.replace('.mp3', ''),
                    course: allocation.course,
                    slot: allocation.slot,
                    playlist_name: newName,
                    metadata: metadata,
                    strategy: strategy
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

        // 统计分配结果
        const allocationStats = {};
        for (const result of results) {
            if (!allocationStats[result.course]) {
                allocationStats[result.course] = 0;
            }
            allocationStats[result.course]++;
        }

        res.json({
            message: `批量公平分配完成：成功 ${results.length} 个，失败 ${errors.length} 个`,
            success: results,
            errors: errors,
            total: files.length,
            strategy: strategy,
            allocationStats: allocationStats
        });
    });
});

// 兼容性接口：旧的批量上传（重定向到新接口）
// app.post('/api/add-songs-batch', rateLimit('batch-upload', 20, 300000), (req, res) => {
//     // 重定向到新的统一接口，使用原始算法
//     req.body.strategy = 'original';
//     return app._router.handle(
//         Object.assign(req, { url: '/api/upload-songs-batch', method: 'POST' }),
//         res
//     );
//                         });

// 兼容性接口：旧的单个上传（重定向到新接口）
// app.post('/api/add-song', rateLimit('upload', 10, 60000), (req, res) => {
//     return app._router.handle(
//         Object.assign(req, { url: '/api/upload-song', method: 'POST' }),
//         res
//     );
//                 });

// 兼容性接口：旧的公平批量上传（重定向到新接口）
// app.post('/api/add-songs-batch-fair', rateLimit('batch-upload', 20, 300000), (req, res) => {
//     // 如果没有指定策略，默认使用轮询分配
//     if (!req.body.strategy) {
//         req.body.strategy = 'round_robin';
//         }
//     return app._router.handle(
//         Object.assign(req, { url: '/api/upload-songs-batch', method: 'POST' }),
//         res
//     );
// });

// 直接上传到指定课程的指定位置
app.post('/api/add-song-to-slot', rateLimit('upload', 10, 60000), (req, res) => {
    upload.single('song')(req, res, async (err) => {
        if (err) {
            console.error('File upload error:', err.message);
            if (err instanceof multer.MulterError) {
                if (err.code === 'LIMIT_FILE_SIZE') {
                    return res.status(400).json({error: '文件太大，最大允许50MB'});
                }
                return res.status(400).json({error: '文件上传错误: ' + err.message});
            }
            return res.status(400).json({error: err.message});
        }

        const {course, slot} = req.body;
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
                display_name: originalName.replace('.mp3', '')
            });
        } catch (error) {
            if (fs.existsSync(file.path)) fs.unlinkSync(file.path);
            res.status(500).json({error: '处理文件失败: ' + error.message});
        }
    });
});

// 按原文件名删除歌曲
app.post('/api/remove-song-by-name', (req, res) => {
    const {original_name} = req.body;
    const data = loadData();

    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        const fileInfo = renamedFiles.find(f =>
            f.original_name === original_name
        );
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
                f => f !== fileInfo
            );

            saveData(data);
            const displayName = fileInfo.original_name.replace('.mp3', '');
            const message = fileDeleted ? `已删除歌曲: ${displayName}` : `已从数据库删除歌曲: ${displayName}（物理文件可能不存在）`;
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
            // 如果文件缺少metadata，尝试重新获取
            let metadata = file.metadata;
            if (!metadata) {
                const filePath = path.join(SONG_DIR, file.playlist_name);
                if (fs.existsSync(filePath)) {
                    // 异步获取元数据会比较复杂，这里提供一个默认结构
                    metadata = {
                        title: file.original_name.replace('.mp3', ''),
                        artist: '未知艺术家',
                        album: '未知专辑',
                        year: '未知年份',
                        genre: '未知流派',
                        duration: 0,
                        hasAlbumArt: false
                    };
                }
            }

            songs.push({
                ...file,
                display_name: file.original_name.replace('.mp3', ''),
                metadata: metadata,
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

        // 重命名歌曲文件 - 只重命名格式不正确的文件，不改变已有的绑定关系
        const renamedFilesList = info.renamed_files || [];
        renamedFilesList.forEach(fileRecord => {
            const currentName = fileRecord.playlist_name;
            const expectedName = generatePlaylistName(course, fileRecord.slot);

            // 只有当当前文件名格式不正确时才重命名
            if (expectedName && expectedName !== currentName) {
                const oldPath = path.join(SONG_DIR, currentName);
                const newPath = path.join(SONG_DIR, expectedName);
                if (fs.existsSync(oldPath)) {
                    fs.renameSync(oldPath, newPath);

                    // 更新记录
                    fileRecord.playlist_name = expectedName;
                    data[course].songs[fileRecord.slot] = expectedName;
                    renamedFiles.push({from: currentName, to: expectedName});
                }
            }
        });
    }

    saveData(data);
    res.json({message: '批量重命名完成', renamed: renamedFiles});
});

// 生成默认音乐图标SVG
function generateDefaultMusicIcon(type = 'song') {
    const icons = {
        song: { icon: '🎵', bg: '#667eea' },
        course: { icon: '📚', bg: '#2196f3' },
        artist: { icon: '🎓', bg: '#ff6b6b' }
    };

    const config = icons[type] || icons.song;

    return `<svg width="60" height="60" xmlns="http://www.w3.org/2000/svg">
        <defs>
            <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" style="stop-color:${config.bg};stop-opacity:1" />
                <stop offset="100%" style="stop-color:${config.bg}dd;stop-opacity:1" />
            </linearGradient>
        </defs>
        <rect width="60" height="60" rx="8" fill="url(#bg)"/>
        <text x="30" y="40" font-family="Arial, sans-serif" font-size="24" text-anchor="middle" fill="white">${config.icon}</text>
    </svg>`;
}

// 获取歌曲封面图片
app.get('/api/album-art/:filename', async (req, res) => {
    const filename = req.params.filename;

    // Security: Validate filename to prevent path traversal attacks
    if (!filename || filename.includes('..') || filename.includes('/') || filename.includes('\\')) {
        return res.status(400).json({error: 'Invalid filename'});
    }

    // Security: Only allow .mp3 files
    if (!filename.endsWith('.mp3')) {
        return res.status(400).json({error: 'Only MP3 files are allowed'});
    }

    const filePath = path.join(SONG_DIR, filename);

    // Security: Ensure the resolved path is within SONG_DIR
    const resolvedPath = path.resolve(filePath);
    const resolvedSongDir = path.resolve(SONG_DIR);
    if (!resolvedPath.startsWith(resolvedSongDir)) {
        return res.status(403).json({error: 'Access denied'});
    }

    console.debug(`封面API请求: ${filename}`, {
        filePath: filePath,
        exists: fs.existsSync(filePath)
    });

    if (!fs.existsSync(filePath)) {
        // 文件不存在，返回默认图标
        console.debug('文件不存在，返回默认图标');
        const defaultSvg = generateDefaultMusicIcon('song');
        res.set('Content-Type', 'image/svg+xml');
        res.set('Cache-Control', 'public, max-age=3600'); // 缓存1小时
        return res.send(defaultSvg);
    }

    try {
        // 检查是否要求无缓存
        const noCache = req.query.nocache === 'true';

        const metadata = await mm.parseFile(filePath, {
            skipCovers: false,
            skipPostHeaders: true,
            includeChapters: false
        });

        console.debug('封面API - 元数据解析结果:', {
            hasCommon: !!metadata.common,
            hasPicture: !!(metadata.common && metadata.common.picture),
            pictureCount: metadata.common?.picture?.length || 0,
            noCache: noCache
        });

        if (metadata.common && metadata.common.picture && metadata.common.picture.length > 0) {
            const picture = metadata.common.picture[0];
            if (picture.data && picture.format) {
                // 确保 data 是 Buffer
                let dataBuffer = picture.data;
                if (Array.isArray(dataBuffer)) {
                    dataBuffer = Buffer.from(dataBuffer);
                    console.debug('封面API - 数组转Buffer成功');
                } else if (dataBuffer instanceof Buffer) {
                    // 已经是 Buffer，直接使用
                    console.debug('封面API - 数据已经是Buffer');
                } else if (typeof dataBuffer === 'object' && dataBuffer.type === 'Buffer' && Array.isArray(dataBuffer.data)) {
                    // Node.js Buffer 对象被序列化后的格式
                    dataBuffer = Buffer.from(dataBuffer.data);
                    console.debug('封面API - 从序列化Buffer对象转换成功');
                } else if (dataBuffer instanceof Uint8Array) {
                    // Uint8Array 类型，转换为 Buffer
                    dataBuffer = Buffer.from(dataBuffer);
                    console.debug('封面API - 从Uint8Array转换为Buffer');
                } else if (typeof dataBuffer === 'object' && dataBuffer.constructor && dataBuffer.constructor.name === 'Uint8Array') {
                    // 确保是 Uint8Array 类型
                    dataBuffer = Buffer.from(dataBuffer);
                    console.debug('封面API - 从Uint8Array对象转换为Buffer');
                } else {
                    // 数据格式错误，返回默认图标
                    console.debug('封面API - 数据格式错误，返回默认图标, 类型:', typeof dataBuffer, '构造函数:', dataBuffer.constructor?.name);
                    const defaultSvg = generateDefaultMusicIcon('song');
                    res.set('Content-Type', 'image/svg+xml');
                    res.set('Cache-Control', 'public, max-age=3600');
                    return res.send(defaultSvg);
                }

                console.debug('封面API - 返回实际封面图片');
                res.set('Content-Type', picture.format);

                // 简化缓存策略：直接使用nocache参数控制
                if (noCache) {
                    res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
                    res.set('Pragma', 'no-cache');
                    res.set('Expires', '0');
                    console.debug('封面API - 使用无缓存模式');
                } else {
                    res.set('Cache-Control', 'public, max-age=86400'); // 缓存1天
                }

                res.send(dataBuffer);
            } else {
                // 封面数据损坏，返回默认图标
                console.debug('封面API - 封面数据损坏，返回默认图标');
                const defaultSvg = generateDefaultMusicIcon('song');
                res.set('Content-Type', 'image/svg+xml');
                res.set('Cache-Control', 'public, max-age=3600');
                res.send(defaultSvg);
            }
        } else {
            // 没有封面图片，根据文件类型返回不同的默认图标
            let iconType = 'song';
            if (filename.match(/^\d{8}(-\d+)?\.mp3$/)) {
                iconType = 'course';
            }

            console.debug(`封面API - 没有封面，返回${iconType}类型默认图标`);
            const defaultSvg = generateDefaultMusicIcon(iconType);
            res.set('Content-Type', 'image/svg+xml');
            res.set('Cache-Control', 'public, max-age=3600'); // 缓存1小时
            res.send(defaultSvg);
        }
    } catch (error) {
        console.debug(`封面API - 解析失败 ${filePath}:`, error.message);
        console.warn(`读取封面失败 ${filePath}:`, error.message);
        // 读取失败，返回默认图标而不是错误
        const defaultSvg = generateDefaultMusicIcon('song');
        res.set('Content-Type', 'image/svg+xml');
        res.set('Cache-Control', 'public, max-age=3600');
        res.send(defaultSvg);
    }
});

// 调试API：分析特定文件的元数据
app.get('/api/debug-metadata/:filename', async (req, res) => {
    const filename = req.params.filename;

    // Security: Validate filename to prevent path traversal attacks
    if (!filename || filename.includes('..') || filename.includes('/') || filename.includes('\\')) {
        return res.status(400).json({error: 'Invalid filename'});
    }

    // Security: Only allow .mp3 files
    if (!filename.endsWith('.mp3')) {
        return res.status(400).json({error: 'Only MP3 files are allowed'});
    }

    const filePath = path.join(SONG_DIR, filename);

    // Security: Ensure the resolved path is within SONG_DIR
    const resolvedPath = path.resolve(filePath);
    const resolvedSongDir = path.resolve(SONG_DIR);
    if (!resolvedPath.startsWith(resolvedSongDir)) {
        return res.status(403).json({error: 'Access denied'});
    }

    if (!fs.existsSync(filePath)) {
        return res.status(404).json({error: '文件不存在'});
    }

    try {
        // 临时启用调试模式
        const originalDebug = DEBUG;

        console.log(`\n=== 调试模式分析文件: ${filename} ===`);

        const metadata = await mm.parseFile(filePath, {
            skipCovers: false,
            skipPostHeaders: false,
            includeChapters: false
        });

        // 详细分析结果
        const analysis = {
            file: filename,
            path: filePath,
            fileSize: fs.statSync(filePath).size,
            metadata: {
                common: metadata.common ? {
                    title: metadata.common.title,
                    artist: metadata.common.artist,
                    album: metadata.common.album,
                    year: metadata.common.year,
                    genre: metadata.common.genre,
                    albumartist: metadata.common.albumartist,
                    track: metadata.common.track,
                    disk: metadata.common.disk,
                    picture_count: metadata.common.picture ? metadata.common.picture.length : 0,
                    all_fields: Object.keys(metadata.common)
                } : null,
                format: metadata.format ? {
                    duration: metadata.format.duration,
                    bitrate: metadata.format.bitrate,
                    sampleRate: metadata.format.sampleRate,
                    numberOfChannels: metadata.format.numberOfChannels,
                    container: metadata.format.container,
                    codec: metadata.format.codec,
                    all_fields: Object.keys(metadata.format)
                } : null,
                native: metadata.native ? Object.keys(metadata.native) : []
            }
        };

        if (metadata.common && metadata.common.picture && metadata.common.picture.length > 0) {
            analysis.pictures = metadata.common.picture.map((pic, index) => ({
                index: index,
                format: pic.format,
                type: pic.type,
                description: pic.description,
                dataType: typeof pic.data,
                dataSize: pic.data ? (Array.isArray(pic.data) ? pic.data.length : pic.data.length) : 0,
                isBuffer: pic.data instanceof Buffer,
                isArray: Array.isArray(pic.data)
            }));
        }

        console.log('调试分析结果:', JSON.stringify(analysis, null, 2));
        console.log(`=== 调试完成: ${filename} ===\n`);

        res.json(analysis);
    } catch (error) {
        console.log(`调试分析失败 ${filePath}:`, error.message);
        res.status(500).json({
            error: error.message,
            file: filename,
            path: filePath
        });
    }
});

// 删除所有歌曲
app.post('/api/delete-all-songs', rateLimit('delete-all', 2, 300000), (req, res) => {
    const data = loadData();
    let deletedCount = 0;
    let errorCount = 0;
    const deletedFiles = [];

    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];

        // 删除所有歌曲文件
        renamedFiles.forEach(fileInfo => {
            const filePath = path.join(SONG_DIR, fileInfo.playlist_name);
            if (fs.existsSync(filePath)) {
                try {
                    fs.unlinkSync(filePath);
                    deletedFiles.push(fileInfo.playlist_name);
                    deletedCount++;
                } catch (error) {
                    console.error(`删除文件失败: ${filePath}`, error);
                    errorCount++;
                }
            }
        });

        // 清空歌曲记录
        data[course].songs = [null, null];
        data[course].renamed_files = [];
    }

    saveData(data);

    res.json({
        message: `删除完成：成功删除 ${deletedCount} 个文件，失败 ${errorCount} 个`,
        deleted_count: deletedCount,
        error_count: errorCount,
        deleted_files: deletedFiles
    });
});

// 更新 music-map：清理不存在的文件绑定
app.post('/api/update-music-map', rateLimit('update-map', 5, 300000), async (req, res) => {
    const data = loadData();
    let cleanedCount = 0;
    let refreshedCount = 0;

    let addedMetadataCount = 0;
    const cleanedFiles = [];

    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        const validFiles = [];

        // 检查每个文件是否存在
        for (const fileInfo of renamedFiles) {
            const filePath = path.join(SONG_DIR, fileInfo.playlist_name);
            if (fs.existsSync(filePath)) {
                // 文件存在，重新获取元数据和图标
                try {
                    const metadata = await getMusicMetadata(filePath);

                    // 检查是否需要添加metadata字段
                    if (!fileInfo.metadata) {
                        console.log(`添加缺失的metadata: ${fileInfo.original_name}`);
                        addedMetadataCount++;
                    }

                    // 不再需要修复封面数据，因为我们不存储图片数据到JSON中

                    fileInfo.metadata = metadata; // 更新元数据
                    validFiles.push(fileInfo);
                    refreshedCount++;
                } catch (error) {
                    console.error(`重新获取元数据失败: ${filePath}`, error);
                    // 即使获取失败，也要确保有基本的metadata结构
                    if (!fileInfo.metadata) {
                        fileInfo.metadata = {
                            title: fileInfo.original_name.replace('.mp3', ''),
                            artist: '未知艺术家',
                            album: '未知专辑',
                            year: '未知年份',
                            genre: '未知流派',
                            duration: 0,
                            hasAlbumArt: false
                        };
                        addedMetadataCount++;
                    }
                    validFiles.push(fileInfo); // 保留原有数据
                }
            } else {
                // 文件不存在，清理绑定
                cleanedFiles.push({
                    course: course,
                    slot: fileInfo.slot,
                    original_name: fileInfo.original_name,
                    playlist_name: fileInfo.playlist_name
                });
                cleanedCount++;
            }
        }

        // 更新文件列表和歌曲位置
        data[course].renamed_files = validFiles;

        // 重新设置歌曲位置
        const newSongs = [null, null];
        validFiles.forEach(fileInfo => {
            if (fileInfo.slot >= 0 && fileInfo.slot < 2) {
                newSongs[fileInfo.slot] = fileInfo.playlist_name;
            }
        });
        data[course].songs = newSongs;
    }

    saveData(data);

    res.json({
        message: `Music-Map 更新完成：清理了 ${cleanedCount} 个无效绑定，刷新了 ${refreshedCount} 个文件的元数据，添加了 ${addedMetadataCount} 个缺失的metadata`,
        cleaned_count: cleanedCount,
        refreshed_count: refreshedCount,

        added_metadata_count: addedMetadataCount,
        cleaned_files: cleanedFiles
    });
});

// 获取所有歌曲的完整信息列表
app.get('/api/all-songs-info', (req, res) => {
    const data = loadData();
    const allSongs = [];

    for (const [course, info] of Object.entries(data)) {
        const renamedFiles = info.renamed_files || [];
        renamedFiles.forEach(fileInfo => {
            allSongs.push({
                course: course,
                original_name: fileInfo.original_name,
                playlist_name: fileInfo.playlist_name,
                slot: fileInfo.slot,
                artist: fileInfo.metadata?.artist || '未知艺术家',
                album: fileInfo.metadata?.album || '未知专辑',
                year: fileInfo.metadata?.year || '未知年份',
                duration: fileInfo.metadata?.duration || 0,
                added_time: fileInfo.added_time
            });
        });
    }

    // 按添加时间排序
    allSongs.sort((a, b) => new Date(b.added_time) - new Date(a.added_time));

    res.json({
        total: allSongs.length,
        songs: allSongs
    });
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

    // 还原已管理的歌曲文件
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
                        display_name: fileRecord.original_name.replace('.mp3', ''),
                        original_name: fileRecord.original_name,
                        playlist_name: fileRecord.playlist_name,
                        type: 'song'
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
    }

    // 还原所有课程文件（包括未在data中的）
    // const allFiles = fs.readdirSync(SONG_DIR).filter(f => f.endsWith('.mp3'));
    // allFiles.forEach(file => {
    //     // 匹配课程文件名：8位数字开头 + 可选 -数字
    //     if (/^\d{8}(-\d+)?\.mp3$/.test(file)) {
    //     try {
    //             const coursePath = path.join(SONG_DIR, file);
    //             const restoredCoursePath = path.join(musicDir, file);
    //
    //         if (fs.existsSync(coursePath)) {
    //                 // 检查是否已经复制过了
    //                 const alreadyRestored = restoredFiles.some(f => f.playlist_name === file);
    //                 if (!alreadyRestored) {
    //             fs.copyFileSync(coursePath, restoredCoursePath);
    //             restoredFiles.push({
    //                         display_name: file.replace('.mp3', ''),
    //                         original_name: file,
    //                         playlist_name: file,
    //                         type: 'course'
    //             });
    //                 }
    //         }
    //     } catch (error) {
    //         errors.push({
    //                 file: file,
    //             error: error.message
    //         });
    //     }
    // }
    // });

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
        .course-meta-info { font-size: 0.9rem; color: #666; margin: 0 15px; }
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
        .alert-info {
            background: #d1ecf1; color: #0c5460; border: 1px solid #bee5eb;
        }
        .alert-warning {
            background: #fff3cd; color: #856404; border: 1px solid #ffeaa7;
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
        #files-preview {display: flex;flex-wrap: wrap}
        .file-item {
            display: flex; justify-content: space-between; align-items: center;
            padding: 10px; background: #f8f9fa; border-radius: 5px; width: 25%;
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
            <div id="cache-status" style="font-size: 0.8em; color: #6c757d; text-align: right; display: flex; justify-content: space-between; align-items: center;">
                <div></div>
                <div>
                    📦 数据缓存: <span id="cache-indicator">未加载</span>
                    <button onclick="universalRefresh()" style="margin-left: 10px; padding: 5px 12px; font-size: 0.85em; border: 1px solid #007bff; background: #007bff; color: white; border-radius: 6px; cursor: pointer; font-weight: 500;">🔄 刷新</button>
                </div>
            </div>
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
                            <!-- 课程和策略选择并排布局 -->
                            <div style="display: flex; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;">
                                <div style="width: auto;display: block; margin-bottom: 5px; font-weight: 600; font-size: 0.9em; padding: 0 20px 0 0;">
                                    <div>📁 课程选择：</div>
                                    <select class="form-control" id="course-select">
                                        <option value="">自动分配到有空位的课程</option>
                                    </select>
                                </div>
                                <div style="width: auto;display: block; margin-bottom: 5px; font-weight: 600; font-size: 0.9em; padding: 0 20px 0 0;">
                                    <div>🎯 分配策略：</div>
                                    <select class="form-control" id="allocation-strategy" onchange="showStrategyInfo()">
                                    <option value="round_robin">🔄 轮询分配（推荐）</option>
                                    <option value="least_songs_first">⚖️ 最少歌曲优先</option>
                                    <option value="random">🎲 随机分配</option>
                                    <option value="original">📝 原始算法</option>
                                </select>
                                </div>
                            </div>
                                
                                <!-- 策略说明 -->
                            <div id="strategy-info" style="background: #e3f2fd; padding: 8px; border-radius: 4px; margin-bottom: 15px; border-left: 3px solid #007bff; font-size: 0.85em; line-height: 1.4;">
                                    <strong>🔄 轮询分配：</strong> 最公平的分配方式。首先为每个有空位的课程分配一首歌曲，确保每个课程都能获得歌曲，然后再填充剩余位置。
                                </div>
                            
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
                                    

                                    
                                    <div style="display: flex; gap: 8px; flex-wrap: wrap;">
                                        <button class="btn btn-success" onclick="uploadBatchFilesSmart()" style="flex: 0 0 auto;">
                                            🎯 上传
                                        </button>
                                        <button class="btn btn-info" onclick="previewAllocation()" style="flex: 0 0 auto;">
                                            👁️ 预览
                                        </button>
                                        <button class="btn btn-outline-info" onclick="compareStrategies()" style="flex: 0 0 auto;">
                                            📊 对比
                                        </button>
                                        <button class="btn btn-secondary" onclick="clearFileList()" style="flex: 0 0 auto;">
                                            🗑️ 清空
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
                            <input type="text" class="form-control" id="delete-song-name" placeholder="输入原文件名..." style="margin-bottom: 10px;">
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
                    <summary>🗑️ 删除所有歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #dc3545; margin-bottom: 15px;">⚠️ 危险操作：将删除所有已上传的歌曲文件和相关记录</p>
                            <button class="btn btn-danger" onclick="deleteAllSongs()">删除所有歌曲</button>
                            <div id="delete-all-result" style="margin-top: 15px;"></div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section">
                    <summary>🔄 更新 Music-Map</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #6c757d; margin-bottom: 15px;">
                                <strong>重新获取所有MP3文件的元数据</strong><br>
                                • 重新读取艺术家、专辑、年份、封面等信息<br>
                                • 清理不存在文件的绑定<br>
                                • 修复缺失的metadata字段
                            </p>
                            <button class="btn btn-warning" onclick="updateMusicMap()">🔄 重新获取元数据</button>
                            <div id="update-map-result" style="margin-top: 15px;"></div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section">
                    <summary>📋 查询所有歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #6c757d; margin-bottom: 15px;">查看所有歌曲的原名称和新名称对照表</p>
                            <button class="btn btn-info" onclick="queryAllSongs()">📋 查询所有歌曲</button>
                            <button class="btn btn-secondary" onclick="copyToClipboard()" id="copy-btn" style="margin-left: 10px; display: none;">📋 复制到剪贴板</button>
                            <div id="all-songs-result" style="margin-top: 15px;"></div>
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

                <details class="collapsible-section">
                    <summary>🔍 查询歌曲</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <input type="text" class="form-control" id="query-song" placeholder="输入歌曲名称..." style="margin-bottom: 10px;">
                            <button class="btn btn-primary" onclick="querySong()">查询</button>
                            <div id="query-result" style="margin-top: 15px;"></div>
                        </div>
                    </div>
                </details>

                <details class="collapsible-section">
                    <summary>🔍 调试元数据</summary>
                    <div class="collapsible-content">
                        <div class="form-group">
                            <p style="color: #6c757d; margin-bottom: 15px;">分析MP3文件的详细元数据信息，帮助诊断识别问题</p>
                            <input type="text" class="form-control" id="debug-filename" placeholder="输入文件名（如：20170221-2-A.mp3）..." style="margin-bottom: 10px;">
                            <button class="btn btn-warning" onclick="debugMetadata()">🔍 分析元数据</button>
                            <div id="debug-result" style="margin-top: 15px;"></div>
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
        
        // 前端数据管理系统
        const DataManager = {
            cache: {
                jsonData: null,        // JSON文件数据（课程绑定关系）
                stats: null,           // 统计数据
                lastJsonUpdate: null,
                lastStatsUpdate: null
            },
            
            // 获取JSON数据（课程绑定关系）- 这是主要的数据源
            async getJsonData(forceRefresh = false) {
                if (!forceRefresh && this.cache.jsonData && this.isJsonDataFresh()) {
                    this.updateCacheIndicator();
                    return this.cache.jsonData;
                }
                
                try {
                    const response = await fetch('/api/list');
                    const data = await response.json();
                    this.cache.jsonData = data;
                    this.cache.lastJsonUpdate = Date.now();
                    allData = data; // 保持向后兼容
                    this.updateCacheIndicator();
                    return data;
                } catch (error) {
                    console.error('获取JSON数据失败:', error);
                    return this.cache.jsonData || {};
                }
            },
            
            // 获取统计数据
            async getStats(forceRefresh = false) {
                if (!forceRefresh && this.cache.stats && this.isStatsDataFresh()) {
                    return this.cache.stats;
                }
                
                try {
                    const response = await fetch('/api/stats');
                    const data = await response.json();
                    this.cache.stats = data;
                    this.cache.lastStatsUpdate = Date.now();
                    return data;
                } catch (error) {
                    console.error('获取统计数据失败:', error);
                    return this.cache.stats || {};
                }
            },
            
            // 生成歌曲列表（从JSON数据）
            async getSongs() {
                const jsonData = await this.getJsonData();
                const songs = [];
                
                for (const [course, info] of Object.entries(jsonData)) {
                    const renamedFiles = info.renamed_files || [];
                    renamedFiles.forEach(file => {
                        songs.push({
                            ...file,
                            display_name: file.original_name.replace('.mp3', ''),
                            course: course
                        });
                    });
                }
                
                allSongs = songs; // 保持向后兼容
                return songs;
            },
            
            // 检查JSON数据是否新鲜（5分钟内）
            isJsonDataFresh() {
                return this.cache.lastJsonUpdate && (Date.now() - this.cache.lastJsonUpdate) < 300000;
            },
            
            // 检查统计数据是否新鲜（10分钟内）
            isStatsDataFresh() {
                return this.cache.lastStatsUpdate && (Date.now() - this.cache.lastStatsUpdate) < 600000;
            },
            
            // 使JSON缓存失效（操作后调用）
            invalidateJsonCache() {
                this.cache.jsonData = null;
                this.cache.lastJsonUpdate = null;
                this.updateCacheIndicator();
            },
            
            // 使统计缓存失效
            invalidateStatsCache() {
                this.cache.stats = null;
                this.cache.lastStatsUpdate = null;
            },
            
            // 操作后的缓存管理
            afterOperation(operation) {
                // 所有操作都会影响JSON数据和统计数据
                this.invalidateJsonCache();
                this.invalidateStatsCache();
            },
            
            // 获取特定歌曲信息（从JSON数据）
            async getSongInfo(fileName) {
                const songs = await this.getSongs();
                return songs.find(s => s.playlist_name === fileName || s.original_name === fileName);
            },
            
            // 获取特定课程信息（从JSON数据）
            async getCourseInfo(courseName) {
                const jsonData = await this.getJsonData();
                return jsonData[courseName];
            },
            
            // 封面图片缓存管理
            getCoverUrl(fileName, options = {}) {
                let url = '/api/album-art/' + encodeURIComponent(fileName);
                
                // 使用nocache参数直接清理缓存
                if (options.noCache) {
                    url += '?nocache=true&t=' + Date.now();
                }
                
                return url;
            },
            
            // 更新缓存状态指示器
            updateCacheIndicator() {
                const indicator = document.getElementById('cache-indicator');
                if (!indicator) return;
                
                const hasJsonData = !!this.cache.jsonData;
                const isJsonFresh = this.isJsonDataFresh();
                
                if (hasJsonData && isJsonFresh) {
                    const age = Math.floor((Date.now() - this.cache.lastJsonUpdate) / 1000);
                    const minutes = Math.floor(age / 60);
                    const seconds = age % 60;
                    const timeStr = minutes > 0 ? minutes + 'm' + seconds + 's前' : seconds + 's前';
                    indicator.innerHTML = '<span style="color: #28a745;">已缓存 (' + timeStr + ')</span>';
                } else if (hasJsonData) {
                    indicator.innerHTML = '<span style="color: #ffc107;">缓存过期 (5分钟)</span>';
                } else {
                    indicator.innerHTML = '<span style="color: #6c757d;">未加载</span>';
                }
            },
            
            // 自动刷新缓存（如果过期）
            async autoRefreshIfNeeded() {
                if (!this.isJsonDataFresh()) {
                    console.log('缓存过期，自动刷新数据...');
                    await this.getJsonData(true);
                }
            },
            

            

        };
        
        function showTab(tabName) {
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.getElementById(tabName).classList.add('active');
            event?.target.classList.add('active');
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
                    
                    const response = await fetch('/api/upload-songs-batch', {
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
                
                DataManager.afterOperation('batch_upload');
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

        // 预览分配计划
        async function previewAllocation() {
            if (selectedFiles.length === 0) {
                alert('请先选择文件');
                return;
            }

            // 清除之前的预览结果
            const filesPreview = document.getElementById('files-preview');
            const existingPreviews = filesPreview.querySelectorAll('[data-type="preview"]');
            existingPreviews.forEach(preview => preview.remove());

            const strategy = document.getElementById('allocation-strategy').value;
            
            try {
                const response = await fetch('/api/preview-fair-allocation', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        songCount: selectedFiles.length,
                        strategy: strategy === 'original' ? 'round_robin' : strategy
                    })
                });

                const result = await response.json();
                
                if (response.ok) {
                    // 显示分配预览 - 使用浮动布局
                    let previewHtml = '<div data-type="preview" style="background: #e3f2fd; padding: 15px; border-radius: 8px; margin: 10px 0; border: 1px solid #bbdefb; width: 100%;">';
                    previewHtml += '<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">';
                    previewHtml += '<h4 style="margin: 0;">📋 分配计划预览</h4>';
                    previewHtml += '<button onclick="this.parentElement.parentElement.remove()" style="background: none; border: none; font-size: 18px; cursor: pointer; color: #666;">×</button>';
                    previewHtml += '</div>';
                    
                    previewHtml += '<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin-bottom: 10px;">';
                    previewHtml += '<div><strong>策略：</strong>' + getStrategyDisplayName(strategy) + '</div>';
                    previewHtml += '<div><strong>歌曲数量：</strong>' + selectedFiles.length + '</div>';
                    previewHtml += '</div>';
                    
                    if (Object.keys(result.allocationStats).length > 0) {
                        previewHtml += '<h5 style="margin: 10px 0 5px 0;">📊 分配统计：</h5>';
                        previewHtml += '<div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(17%, 1fr)); gap: 6px; max-height: 250px; overflow-y: auto;">';
                        for (const [course, count] of Object.entries(result.allocationStats)) {
                            previewHtml += '<div style="background: white; padding: 4px 8px; border-radius: 3px; border: 1px solid #e0e0e0; font-size: 0.85em; text-align: center;">';
                            previewHtml += course.replace('.mp3', '') + '(' + count + ')';
                            previewHtml += '</div>';
                        }
                        previewHtml += '</div>';
                    }
                    
                    previewHtml += '</div>';
                    
                    // 在文件预览区域显示
                    const filesPreview = document.getElementById('files-preview');
                    filesPreview.innerHTML = previewHtml + filesPreview.innerHTML;
                    
                    showAlert(result.message, 'info');
                } else {
                    showAlert('预览失败: ' + result.error, 'error');
                }
            } catch (error) {
                showAlert('预览失败: ' + error.message, 'error');
            }
        }

        // 获取策略显示名称
        function getStrategyDisplayName(strategy) {
            const strategyNames = {
                'round_robin': '🔄 轮询分配',
                'least_songs_first': '⚖️ 最少歌曲优先',
                'random': '🎲 随机分配',
                'original': '📝 原始算法'
            };
            return strategyNames[strategy] || strategy;
        }

        // 显示策略信息
        function showStrategyInfo() {
            const strategy = document.getElementById('allocation-strategy').value;
            const infoDiv = document.getElementById('strategy-info');
            
            const strategyInfos = {
                'round_robin': {
                    title: '🔄 轮询分配',
                    description: '公平分配策略。首先为每个有空位的课程分配一首歌曲，然后按歌曲数量平衡填充剩余位置。',
                    color: '#007bff'
                },
                'least_songs_first': {
                    title: '⚖️ 最少歌曲优先',
                    description: '公平分配策略。优先为歌曲数量最少的课程分配，最大化平衡各课程的歌曲数量。',
                    color: '#28a745'
                },
                'random': {
                    title: '🎲 随机分配',
                    description: '纯随机策略。每次都从所有有空位的课程中完全随机选择，不考虑平衡性。',
                    color: '#ffc107'
                },
                'original': {
                    title: '📝 原始算法',
                    description: '传统顺序分配。严格按课程名称顺序依次填满每个课程，直到该课程满了再转到下一个。',
                    color: '#6c757d'
                }
            };
            
            const info = strategyInfos[strategy];
            if (info && infoDiv) {
                const content = '<strong>' + info.title + '：</strong> ' + info.description;
                    infoDiv.innerHTML = content;
                    infoDiv.style.borderLeftColor = info.color;
                }
        }

        // 智能上传函数 - 根据选择的策略决定使用哪种算法
        async function uploadBatchFilesSmart() {
            const strategy = document.getElementById('allocation-strategy').value;
            
            if (strategy === 'original') {
                // 使用原始算法
                return await uploadBatchFiles();
            } else {
                // 使用公平分配算法
                return await uploadBatchFilesFair();
            }
        }

        // 策略对比
        async function compareStrategies() {
            if (selectedFiles.length === 0) {
                alert('请先选择文件进行对比');
                return;
            }

            // 清除之前的对比结果
            const filesPreview = document.getElementById('files-preview');
            const existingComparisons = filesPreview.querySelectorAll('[data-type="comparison"]');
            existingComparisons.forEach(comparison => comparison.remove());

            const strategies = ['round_robin', 'least_songs_first', 'random'];
            const songCount = selectedFiles.length;
            
            try {
                const comparisons = await Promise.all(
                    strategies.map(async strategy => {
                        const response = await fetch('/api/preview-fair-allocation', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ songCount, strategy })
                        });
                        const result = await response.json();
                        return { strategy, result };
                    })
                );

                // 显示对比结果 - 优化响应式布局
                let comparisonHtml = '<div data-type="comparison" style="background: #fff3cd; padding: 15px; border-radius: 8px; margin: 10px 0; border: 1px solid #ffeaa7; width: 100%;">';
                comparisonHtml += '<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">';
                comparisonHtml += '<h4 style="margin: 0;">📊 分配策略对比 (歌曲数量: ' + songCount + ')</h4>';
                comparisonHtml += '<button onclick="this.parentElement.parentElement.remove()" style="background: none; border: none; font-size: 18px; cursor: pointer; color: #666;">×</button>';
                comparisonHtml += '</div>';
                
                // 使用响应式网格布局显示策略对比
                comparisonHtml += '<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(32%, 1fr)); gap: 12px;">';
                
                for (const comparison of comparisons) {
                    const { strategy, result } = comparison;
                    comparisonHtml += '<div style="background: white; padding: 10px; border-radius: 6px; border: 1px solid #e0e0e0;">';
                    comparisonHtml += '<h5 style="margin: 0 0 6px 0; color: #1976d2; font-size: 0.95em;">' + getStrategyDisplayName(strategy) + '</h5>';
                    
                    if (result.allocationStats) {
                        const courses = Object.keys(result.allocationStats);
                        const avgSongs = songCount / courses.length;
                        comparisonHtml += '<p style="margin: 3px 0; font-size: 0.85em;">分配到 <strong>' + courses.length + '</strong> 个课程</p>';
                        
                        // 使用紧凑的统计显示格式
                        comparisonHtml += '<div style="margin-top: 6px;">';
                        comparisonHtml += '<div style="font-size: 0.8em; line-height: 1.3; word-break: break-all; max-height: 250px; overflow-y: auto; display: grid; grid-template-columns: repeat(auto-fit, minmax(49%, 1fr)); gap: 2px;">';
                        for (const [course, count] of Object.entries(result.allocationStats)) {
                            comparisonHtml += '<div style="background: white; padding: 4px 8px; margin: 0 5px; border-radius: 3px; border: 1px solid #e0e0e0; font-size: 0.85em; text-align: center;">';
                            comparisonHtml += course.replace('.mp3', '') + '(' + count + ')';
                            comparisonHtml += '</div>';
                        }
                        // comparisonHtml += statsText;
                        comparisonHtml += '</div>';
                        comparisonHtml += '</div>';
                    }
                    comparisonHtml += '</div>';
                }
                
                comparisonHtml += '</div></div>';
                
                // 在文件预览区域显示
                const filesPreview = document.getElementById('files-preview');
                filesPreview.innerHTML = comparisonHtml + filesPreview.innerHTML;
                
                showAlert('策略对比完成，请查看详细结果', 'info');
                
            } catch (error) {
                showAlert('策略对比失败: ' + error.message, 'error');
            }
        }

        // 公平分配批量上传
        async function uploadBatchFilesFair() {
            if (selectedFiles.length === 0) {
                alert('请先选择文件');
                return;
            }
            
            const strategy = document.getElementById('allocation-strategy').value;
            
            // 显示进度条
            const progressDiv = document.getElementById('upload-progress');
            const progressFill = document.getElementById('progress-fill');
            const progressText = document.getElementById('progress-text');
            
            progressDiv.style.display = 'block';
            progressFill.style.width = '0%';
            progressText.textContent = '准备公平分配上传...';
            
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
                    
                    progressText.textContent = '公平分配第 ' + (batchIndex + 1) + '/' + batches.length + ' 批...';
                    
                    const formData = new FormData();
                    formData.append('strategy', strategy === 'original' ? 'round_robin' : strategy);
                    
                    batch.forEach(file => {
                        formData.append('songs', file);
                    });
                    
                    const response = await fetch('/api/upload-songs-batch', {
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
                progressText.textContent = '公平分配完成：成功 ' + allResults.length + ' 个，失败 ' + allErrors.length + ' 个';
                
                const successMessage = '批量公平分配完成：成功 ' + allResults.length + ' 个，失败 ' + allErrors.length + ' 个';
                showAlert(successMessage, allErrors.length === 0 ? 'success' : 'warning');
                
                    
                
                // 显示错误详情
                if (allErrors.length > 0) {
                    allErrors.forEach(err => {
                        showAlert(err.file + ': ' + err.error, 'error');
                    });
                }
                
                DataManager.afterOperation('batch_fair_upload');
                clearFileList();
                loadSongs();
                loadCourses();
                
            } catch (error) {
                progressText.textContent = '公平分配失败';
                showAlert('批量公平分配失败: ' + error.message, 'error');
            }
            
            setTimeout(() => {
                progressDiv.style.display = 'none';
            }, 5000);
        }
        async function loadOverview() {
            try {
                const [stats, songs] = await Promise.all([
                    DataManager.getStats(),
                    DataManager.getSongs()
                ]);
                
                document.getElementById('stats-grid').innerHTML = 
                    '<div class="stat-card" onclick="showTab(\\'courses\\'); document.querySelector(\\'button[onclick*=courses]\\').click();">' +
                        '<div class="stat-number">' + stats.total_courses + '</div>' +
                        '<div class="stat-label">总课程数</div>' +
                    '</div>' +
                    '<div class="stat-card" onclick="showTab(\\'songs\\'); document.querySelector(\\'button[onclick*=songs]\\').click();">' +
                        '<div class="stat-number">' + stats.total_songs + '</div>' +
                        '<div class="stat-label">总歌曲数</div>' +
                    '</div>' +
                    '<div class="stat-card" onclick="showTab(\\'courses\\'); document.querySelector(\\'button[onclick*=courses]\\').click();">' +
                        '<div class="stat-number">' + stats.courses_with_songs + '</div>' +
                        '<div class="stat-label">有歌曲的课程</div>' +
                    '</div>' +
                    '<div class="stat-card" onclick="showTab(\\'songs\\'); document.querySelector(\\'button[onclick*=songs]\\').click();">' +
                        '<div class="stat-number">' + stats.empty_slots + '</div>' +
                        '<div class="stat-label">空闲位置</div>' +
                    '</div>';
                    
                const recent = songs.sort((a,b) => new Date(b.added_time) - new Date(a.added_time)).slice(0,5);
                document.getElementById('recent-songs').innerHTML = recent.length ? 
                    recent.map(s => 
                        '<div class="song-item" style="display: flex; align-items: center; justify-content: space-between;">' +
                            '<div style="flex: 1;">' +
                                '<div class="song-title">🎵 ' + s.display_name + ' | 🎤 ' + (s.metadata?.artist || '未知艺术家') + ' | 📅 ' + (s.metadata?.year || '未知年份') + ' | 📚 ' + s.course.replace('.mp3', '') + ' | 📁 ' + s.playlist_name.replace('.mp3', '') + '</div>' +
                            '</div>' +
                            '<div style="display: flex; gap: 10px;">' +
                                '<button class="btn btn-primary" onclick="playAudio(\\'/songs/' + s.playlist_name + '\\', ' + JSON.stringify(s).replace(/"/g, '&quot;') + ')">▶️ 播放</button>' +
                            '</div>' +
                        '</div>'
                    ).join('') : '<div class="empty-slot">暂无歌曲</div>';
            } catch (e) { console.error('加载失败:', e); }
        }
        async function loadCourses() {
            try {
                const data = await DataManager.getJsonData();
                displayCourses(data);
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
                        const displayName = fileInfo ? fileInfo.original_name.replace('.mp3', '') : songFileName;
                        return \`
                            <div class="song-slot">
                                <div class="song-info">
                                    <div class="song-title">🎵 \${displayName} | 🎤 \${meta?.artist || '未知'} | 📅 \${meta?.year || '未知'} | 📁 \${songFileName}</div>
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
                    (f.original_name && f.original_name.toLowerCase().includes(query)) ||
                    (f.metadata?.title && f.metadata.title.toLowerCase().includes(query)) ||
                    (f.metadata?.artist && f.metadata.artist.toLowerCase().includes(query)) ||
                    (f.metadata?.year && f.metadata.year.toString().includes(query))
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
                // 从JSON数据中查找歌曲信息
                const fileName = src.split('/').pop();
                songData = await DataManager.getSongInfo(fileName);
                
                // 如果不是歌曲，可能是课程文件
                if (!songData) {
                    const courses = await DataManager.getJsonData();
                    const courseInfo = courses[fileName];
                    if (courseInfo) {
                        songData = {
                            display_name: courseInfo.course_metadata?.title || fileName.replace('.mp3', ''),
                            metadata: courseInfo.course_metadata || {}
                        };
                    }
                }
            }
            
            // 创建新的播放器
            const player = document.createElement('div');
            player.id = 'audio-player';
            player.style.cssText = 'position: fixed; bottom: 20px; right: 20px; background: white; padding: 20px; border-radius: 15px; box-shadow: 0 15px 40px rgba(0,0,0,0.3); z-index: 10000; min-width: 350px; max-width: 400px;';
            
            const songTitle = songData?.display_name || src.split('/').pop().replace('.mp3', '');
            const artist = songData?.metadata?.artist || '未知艺术家';
            const album = songData?.metadata?.album || '未知专辑';
            const year = songData?.metadata?.year || '未知年份';
            const hasAlbumArt = songData?.metadata?.hasAlbumArt;
            
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
            
            // 总是使用实时API获取封面，浏览器会自动缓存
            albumArtHtml = '<img id="cover-image-' + fileName.replace(/[^a-zA-Z0-9]/g, '') + '" ' +
                         'src="' + DataManager.getCoverUrl(fileName, { noCache: true }) + '" ' +
                         'style="width: 60px; height: 60px; border-radius: 8px; object-fit: cover; border: 2px solid #e9ecef;" ' +
                         'alt="封面">';
            
            
            // todo '<div style="font-size: 0.85rem; color: #6c757d;">🎤 ' + artist + ' ｜ 💿 ' + album + '</div>' + 超过长度隐藏
            player.innerHTML = 
                '<div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 15px;">' +
                    '<strong style="color: #495057;">🎵 正在播放</strong>' +
                    '<button onclick="document.getElementById(\\'audio-player\\').remove()" style="background: none; border: none; font-size: 1.2rem; cursor: pointer; color: #6c757d;">✕</button>' +
                '</div>' +
                
                '<div style="display: flex; align-items: center; margin-bottom: 15px;">' +
                    '<div style="margin-right: 15px;">' +
                        albumArtHtml +
                    '</div>' +
                    '<div style="flex: 1;">' +
                        '<div style="font-weight: 600; color: #495057; margin-bottom: 3px; font-size: 1rem;">' + songTitle + '</div>' +
                        '<div style="font-size: 0.85rem; color: #6c757d;">🎤 ' + artist + ' | 💿 ' + album +
                        '</div><div style="font-size: 0.8rem; color: #adb5bd;">📁 ' + src.split('/').pop().replace('.mp3', '') +
                         ' | 📅 ' + year + '</div>' +
                    '</div>' +
                '</div>' +
                
                '<audio controls autoplay style="width: 100%; margin-bottom: 10px;">' +
                    '<source src="' + src + '" type="audio/mpeg">' +
                    '您的浏览器不支持音频播放' +
                '</audio>'
            
            document.body.appendChild(player);
        }
        
        
        // 万能刷新功能：使用nocache参数直接清理缓存
        async function universalRefresh() {
            const indicator = document.getElementById('cache-indicator');
            if (indicator) {
                indicator.innerHTML = '<span style="color: #007bff;">刷新中...</span>';
            }
            
            try {
                // 1. 刷新JSON数据
                if (indicator) {
                    indicator.innerHTML = '<span style="color: #007bff;">刷新JSON...</span>';
                }
                
                try {
                    await DataManager.getJsonData(true);
                    showAlert('JSON数据已刷新', 'success');
                } catch (error) {
                    showAlert('刷新失败: ' + error.message, 'error');
                }
                
                // 2. 使用nocache参数刷新所有封面图片
                const images = document.querySelectorAll('img[id^="cover-image-"]');
                let refreshedCoverCount = 0;
                
                images.forEach(img => {
                    const currentSrc = img.src;
                    const urlMatch = currentSrc.match(/\\/api\\/album-art\\/([^?]+)/);
                    if (urlMatch) {
                        const fileName = decodeURIComponent(urlMatch[1]);
                        // 直接使用nocache参数，简单有效
                        img.src = DataManager.getCoverUrl(fileName, { noCache: true });
                        refreshedCoverCount++;
                    }
                });
                
                // 3. 重新加载当前页面内容
                const currentTab = document.querySelector('.tab.active');
                if (currentTab) {
                    const tabName = currentTab.textContent.includes('概览') ? 'overview' : 
                                   currentTab.textContent.includes('课程') ? 'courses' : 'songs';
                    showTab(tabName);
                }
                
                showAlert('刷新完成：JSON数据和 ' + refreshedCoverCount + ' 个封面已更新', 'success');
                
            } catch (error) {
                showAlert('刷新失败: ' + error.message, 'error');
                if (indicator) {
                    indicator.innerHTML = '<span style="color: #dc3545;">刷新失败</span>';
                }
            }
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
            const formData = new FormData();
            formData.append('course', course);
            formData.append('slot', slot);
            formData.append('song', file);

            
            try {
                const response = await fetch('/api/add-song-to-slot', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                if (response.ok) {
                    showAlert(\`歌曲已添加到 \${course} 位置 \${parseInt(slot) + 1}: \${result.display_name}\`, 'success');
                    DataManager.afterOperation('upload');
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
                const [songs, data] = await Promise.all([
                    DataManager.getSongs(),
                    DataManager.getJsonData()
                ]);
                
                document.getElementById('course-select').innerHTML = '<option value="">自动分配到有空位的课程</option>' + 
                    Object.keys(data).sort().map(c => '<option value="' + c + '">' + c + '</option>').join('');
                displaySongs(songs);
                initDragDrop(); // 初始化拖拽功能
            } catch (e) { console.error('加载失败:', e); }
        }
        function displaySongs(songs) {
            const songsList = document.getElementById('songs-list');
            if (songs.length === 0) {
                songsList.innerHTML = '<div class="empty-slot">暂无歌曲</div>';
                return;
            }
            
            songsList.innerHTML = songs.map(s => 
                '<div class="song-item" style="display: flex; align-items: center; justify-content: space-between;">' +
                    '<div style="flex: 1;">' +
                        '<div class="song-title">🎵 ' + s.display_name + ' | 🎤 ' + (s.metadata?.artist || '未知艺术家') + ' | 📅 ' + (s.metadata?.year || '未知年份') + ' | 📚 ' + s.course.replace('.mp3', '') + ' | 📁 ' + s.playlist_name.replace('.mp3', '') + '</div>' +
                    '</div>' +
                    '<div style="display: flex; gap: 10px;">' +
                        '<button class="btn btn-primary" onclick="playAudio(\\'/songs/' + s.playlist_name + '\\', ' + JSON.stringify(s).replace(/"/g, '&quot;') + ')">▶️ 播放</button>' +
                        '<button class="btn btn-danger" onclick="deleteSongByOriginalName(\\'' + s.original_name + '\\')">🗑️ 删除</button>' +
                    '</div>' +
                '</div>'
            ).join('');
        }
        function searchSongs() {
            const q = document.getElementById('song-search').value.toLowerCase();
            displaySongs(allSongs.filter(s => s.display_name.toLowerCase().includes(q) || (s.metadata?.artist && s.metadata.artist.toLowerCase().includes(q)) || s.course.toLowerCase().includes(q)));
        }

        async function deleteSongByName() {
            const name = document.getElementById('delete-song-name').value;
            if (!name) return alert('请输入原文件名');
            if (!confirm('确定删除 "' + name + '"？')) return;
            try {
                const res = await fetch('/api/remove-song-by-name', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({original_name: name})});
                const result = await res.json();
                if (res.ok) {
                    showAlert(result.message, 'success');
                    document.getElementById('delete-song-name').value = '';
                    DataManager.afterOperation('delete');
                    loadSongs(); loadCourses();
                } else showAlert('删除失败: ' + result.error, 'error');
            } catch (e) { showAlert('删除失败: ' + e.message, 'error'); }
        }

        async function deleteSongByOriginalName(originalName) {
            if (!confirm('确定删除 "' + originalName.replace('.mp3', '') + '"？')) return;
            try {
                const res = await fetch('/api/remove-song-by-name', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({original_name: originalName})});
                const result = await res.json();
                if (res.ok) {
                    showAlert(result.message, 'success');
                    DataManager.afterOperation('delete');
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
                DataManager.afterOperation('rename');
                loadCourses();
            } catch (e) { showAlert('失败: ' + e.message, 'error'); }
        }
        async function querySong() {
            const name = document.getElementById('query-song').value;
            if (!name) return;
            try {
                const res = await fetch('/api/song-exists?name=' + encodeURIComponent(name));
                const result = await res.json();
                if (result.exists && result.info) {
                    const displayName = result.info.original_name.replace('.mp3', '');
                    document.getElementById('query-result').innerHTML = \`<div class="alert alert-success"><strong>找到歌曲！</strong><br>原文件名: \${result.info.original_name}<br>显示名称: \${displayName}<br>所属课程: \${result.course}<br>艺术家: \${result.info.metadata?.artist || '未知艺术家'}<br>年份: \${result.info.metadata?.year || '未知年份'}<br>新文件名: \${result.info.playlist_name}</div>\`;
                } else {
                    document.getElementById('query-result').innerHTML = '<div class="alert alert-error">未找到匹配的歌曲</div>';
                }
            } catch (e) { document.getElementById('query-result').innerHTML = '<div class="alert alert-error">查询失败</div>'; }
        }

        async function debugMetadata() {
            const filename = document.getElementById('debug-filename').value;
            if (!filename) {
                alert('请输入文件名');
                return;
            }
            
            const resultDiv = document.getElementById('debug-result');
            resultDiv.innerHTML = '<div class="alert alert-info">正在分析元数据...</div>';
            
            try {
                const response = await fetch('/api/debug-metadata/' + encodeURIComponent(filename));
                const result = await response.json();
                
                if (response.ok) {
                    let html = '<div class="alert alert-success"><strong>元数据分析完成</strong></div>';
                    html += '<div style="background: #f8f9fa; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 0.9em; max-height: 500px; overflow-y: auto;">';
                    
                    html += '<h5>📁 文件信息</h5>';
                    html += '<div>文件名: ' + result.file + '</div>';
                    html += '<div>文件大小: ' + (result.fileSize / 1024 / 1024).toFixed(2) + ' MB</div><br>';
                    
                    if (result.metadata.common) {
                        html += '<h5>🎵 基本信息</h5>';
                        html += '<div>标题: ' + (result.metadata.common.title || '未设置') + '</div>';
                        html += '<div>艺术家: ' + (result.metadata.common.artist || '未设置') + '</div>';
                        html += '<div>专辑: ' + (result.metadata.common.album || '未设置') + '</div>';
                        html += '<div>年份: ' + (result.metadata.common.year || '未设置') + '</div>';
                        html += '<div>流派: ' + (result.metadata.common.genre ? result.metadata.common.genre.join(', ') : '未设置') + '</div>';
                        html += '<div>专辑艺术家: ' + (result.metadata.common.albumartist || '未设置') + '</div>';
                        html += '<div>曲目: ' + (result.metadata.common.track ? JSON.stringify(result.metadata.common.track) : '未设置') + '</div><br>';
                        
                        html += '<h5>📋 所有Common字段</h5>';
                        html += '<div>' + result.metadata.common.all_fields.join(', ') + '</div><br>';
                    } else {
                        html += '<div class="alert alert-warning">⚠️ 没有找到 common 元数据</div>';
                    }
                    
                    if (result.metadata.format) {
                        html += '<h5>🔧 格式信息</h5>';
                        html += '<div>时长: ' + (result.metadata.format.duration ? result.metadata.format.duration.toFixed(2) + 's' : '未知') + '</div>';
                        html += '<div>比特率: ' + (result.metadata.format.bitrate || '未知') + '</div>';
                        html += '<div>采样率: ' + (result.metadata.format.sampleRate || '未知') + '</div>';
                        html += '<div>声道数: ' + (result.metadata.format.numberOfChannels || '未知') + '</div>';
                        html += '<div>容器格式: ' + (result.metadata.format.container || '未知') + '</div>';
                        html += '<div>编解码器: ' + (result.metadata.format.codec || '未知') + '</div><br>';
                        
                        html += '<h5>📋 所有Format字段</h5>';
                        html += '<div>' + result.metadata.format.all_fields.join(', ') + '</div><br>';
                    }
                    
                    if (result.pictures && result.pictures.length > 0) {
                        html += '<h5>🖼️ 封面图片信息</h5>';
                        result.pictures.forEach(pic => {
                            html += '<div>图片 ' + (pic.index + 1) + ':</div>';
                            html += '<div>  - 格式: ' + (pic.format || '未知') + '</div>';
                            html += '<div>  - 类型: ' + (pic.type || '未知') + '</div>';
                            html += '<div>  - 描述: ' + (pic.description || '无') + '</div>';
                            html += '<div>  - 数据类型: ' + pic.dataType + '</div>';
                            html += '<div>  - 数据大小: ' + (pic.dataSize / 1024).toFixed(2) + ' KB</div>';
                            html += '<div>  - 是Buffer: ' + pic.isBuffer + '</div>';
                            html += '<div>  - 是数组: ' + pic.isArray + '</div><br>';
                        });
                    } else {
                        html += '<div class="alert alert-warning">⚠️ 没有找到封面图片</div>';
                    }
                    
                    if (result.metadata.native && result.metadata.native.length > 0) {
                        html += '<h5>🔖 原生标签格式</h5>';
                        html += '<div>' + result.metadata.native.join(', ') + '</div>';
                    }
                    
                    html += '</div>';
                    html += '<div style="margin-top: 15px;"><button class="btn btn-secondary" onclick="copyDebugInfo("" + filename + "")">📋 复制调试信息</button></div>';
                    
                    resultDiv.innerHTML = html;
                    
                    // 保存调试数据用于复制
                    window.lastDebugResult = result;
                    
                } else {
                    resultDiv.innerHTML = '<div class="alert alert-error">分析失败: ' + result.error + '</div>';
                }
            } catch (error) {
                resultDiv.innerHTML = '<div class="alert alert-error">分析失败: ' + error.message + '</div>';
            }
        }

        function copyDebugInfo(filename) {
            if (!window.lastDebugResult) {
                alert('没有调试数据可复制');
                return;
            }
            
            const result = window.lastDebugResult;
            let text = '=== MP3元数据调试报告 ===\\n';
            text += '文件名: ' + result.file + '\\n';
            text += '文件大小: ' + (result.fileSize / 1024 / 1024).toFixed(2) + ' MB\\n\\n';
            
            if (result.metadata.common) {
                text += '【基本信息】\\n';
                text += '标题: ' + (result.metadata.common.title || '未设置') + '\\n';
                text += '艺术家: ' + (result.metadata.common.artist || '未设置') + '\\n';
                text += '专辑: ' + (result.metadata.common.album || '未设置') + '\\n';
                text += '年份: ' + (result.metadata.common.year || '未设置') + '\\n';
                text += '流派: ' + (result.metadata.common.genre ? result.metadata.common.genre.join(', ') : '未设置') + '\\n';
                text += '专辑艺术家: ' + (result.metadata.common.albumartist || '未设置') + '\\n\\n';
                
                text += '【所有Common字段】\\n' + result.metadata.common.all_fields.join(', ') + '\\n\\n';
            }
            
            if (result.metadata.format) {
                text += '【格式信息】\\n';
                text += '时长: ' + (result.metadata.format.duration ? result.metadata.format.duration.toFixed(2) + 's' : '未知') + '\\n';
                text += '比特率: ' + (result.metadata.format.bitrate || '未知') + '\\n';
                text += '采样率: ' + (result.metadata.format.sampleRate || '未知') + '\\n';
                text += '声道数: ' + (result.metadata.format.numberOfChannels || '未知') + '\\n';
                text += '容器格式: ' + (result.metadata.format.container || '未知') + '\\n';
                text += '编解码器: ' + (result.metadata.format.codec || '未知') + '\\n\\n';
            }
            
            if (result.pictures && result.pictures.length > 0) {
                text += '【封面图片】\\n';
                result.pictures.forEach(pic => {
                    text += '图片 ' + (pic.index + 1) + ': ' + (pic.format || '未知') + ', ' + (pic.dataSize / 1024).toFixed(2) + ' KB\\n';
                });
                text += '\\n';
            }
            
            if (result.metadata.native && result.metadata.native.length > 0) {
                text += '【原生标签格式】\\n' + result.metadata.native.join(', ') + '\\n';
            }
            
            text += '\\n=== 报告结束 ===';
            
            navigator.clipboard.writeText(text).then(() => {
                showAlert('调试信息已复制到剪贴板', 'success');
            }).catch(() => {
                showAlert('复制失败，请手动复制', 'error');
            });
        }
        
        async function deleteAllSongs() {
            if (!confirm('⚠️ 危险操作！\\n\\n确定要删除所有已上传的歌曲吗？\\n这将永久删除所有歌曲文件和相关记录，无法恢复！')) return;
            
            try {
                const response = await fetch('/api/delete-all-songs', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'}
                });
                
                const result = await response.json();
                const resultDiv = document.getElementById('delete-all-result');
                
                if (response.ok) {
                    resultDiv.innerHTML = 
                        '<div class="alert alert-success">' +
                        '<strong>' + result.message + '</strong><br>' +
                        '删除文件数: ' + result.deleted_count + ' 个<br>' +
                        '失败文件数: ' + result.error_count + ' 个' +
                        '</div>';
                    
                    showAlert(result.message, 'success');
                    DataManager.afterOperation('delete');
                    loadSongs();
                    loadCourses();
                } else {
                    resultDiv.innerHTML = '<div class="alert alert-error">删除失败: ' + result.error + '</div>';
                    showAlert('删除失败: ' + result.error, 'error');
                }
            } catch (error) {
                const resultDiv = document.getElementById('delete-all-result');
                resultDiv.innerHTML = '<div class="alert alert-error">删除失败: ' + error.message + '</div>';
                showAlert('删除失败: ' + error.message, 'error');
            }
        }

        let allSongsData = []; // 存储查询结果用于复制

        async function queryAllSongs() {
            try {
                const response = await fetch('/api/all-songs-info');
                const result = await response.json();
                const resultDiv = document.getElementById('all-songs-result');
                const copyBtn = document.getElementById('copy-btn');
                
                if (response.ok) {
                    allSongsData = result.songs; // 保存数据用于复制
                    
                    let html = '<div class="alert alert-success">';
                    html += '<strong>找到 ' + result.total + ' 首歌曲</strong></div>';
                    
                    if (result.songs.length > 0) {
                        html += '<div style="max-height: 400px; overflow-y: auto; border: 1px solid #e9ecef; border-radius: 8px; padding: 10px; background: #f8f9fa;">';
                        
                        result.songs.forEach((song, index) => {
                            const duration = song.duration > 0 ? Math.floor(song.duration / 60) + ':' + String(song.duration % 60).padStart(2, '0') : '未知';
                            html += '<div style="padding: 8px; border-bottom: 1px solid #e9ecef; ' + (index % 2 === 0 ? 'background: white;' : '') + '">';
                            html += '<div><strong>原文件名:</strong> ' + song.original_name + '</div>';
                            html += '<div><strong>新文件名:</strong> ' + song.playlist_name + '</div>';
                            html += '<div style="font-size: 0.9em; color: #6c757d;">';
                            html += '📚 ' + song.course.replace('.mp3', '') + ' | ';
                            html += '🎤 ' + song.artist + ' | ';
                            html += '💿 ' + song.album + ' | ';
                            html += '📅 ' + song.year + ' | ';
                            html += '⏱️ ' + duration;
                            html += '</div></div>';
                        });
                        
                        html += '</div>';
                        copyBtn.style.display = 'inline-block';
                    } else {
                        html += '<div class="alert alert-warning">暂无歌曲</div>';
                        copyBtn.style.display = 'none';
                    }
                    
                    resultDiv.innerHTML = html;
                } else {
                    resultDiv.innerHTML = '<div class="alert alert-error">查询失败: ' + result.error + '</div>';
                    copyBtn.style.display = 'none';
                }
            } catch (error) {
                const resultDiv = document.getElementById('all-songs-result');
                resultDiv.innerHTML = '<div class="alert alert-error">查询失败: ' + error.message + '</div>';
                document.getElementById('copy-btn').style.display = 'none';
            }
        }

        async function copyToClipboard() {
            if (allSongsData.length === 0) {
                alert('没有数据可复制');
                return;
            }
            
            let text = '歌曲对照表\\n';
            text += '='.repeat(50) + '\\n';
            text += '总计: ' + allSongsData.length + ' 首歌曲\\n\\n';
            
            allSongsData.forEach((song, index) => {
                const duration = song.duration > 0 ? Math.floor(song.duration / 60) + ':' + String(song.duration % 60).padStart(2, '0') : '未知';
                text += (index + 1) + '. ' + song.original_name + '\\n';
                text += '   → ' + song.playlist_name + '\\n';
                text += '   📚 ' + song.course.replace('.mp3', '') + ' | 🎤 ' + song.artist + ' | 💿 ' + song.album + ' | 📅 ' + song.year + ' | ⏱️ ' + duration + '\\n\\n';
            });
            
            try {
                await navigator.clipboard.writeText(text);
                showAlert('歌曲列表已复制到剪贴板', 'success');
            } catch (error) {
                // 如果剪贴板API失败，尝试使用传统方法
                const textArea = document.createElement('textarea');
                textArea.value = text;
                document.body.appendChild(textArea);
                textArea.select();
                try {
                    document.execCommand('copy');
                    showAlert('歌曲列表已复制到剪贴板', 'success');
                } catch (e) {
                    showAlert('复制失败，请手动复制', 'error');
                }
                document.body.removeChild(textArea);
            }
        }

        async function updateMusicMap() {
            if (!confirm('确定要更新 Music-Map 吗？\\n\\n这将：\\n1. 清理不存在文件的绑定\\n2. 重新获取所有文件的元数据和图标')) return;
            
            try {
                const response = await fetch('/api/update-music-map', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'}
                });
                
                const result = await response.json();
                const resultDiv = document.getElementById('update-map-result');
                
                if (response.ok) {
                    resultDiv.innerHTML = 
                        '<div class="alert alert-success">' +
                        '<strong>' + result.message + '</strong><br>' +
                        '清理的无效绑定: ' + result.cleaned_count + ' 个<br>' +
                        '刷新的文件: ' + result.refreshed_count + ' 个<br>' +
                        '修复的封面: ' + (result.fixed_cover_count || 0) + ' 个<br>' +
                        '添加的metadata: ' + (result.added_metadata_count || 0) + ' 个' +
                        '</div>';
                    
                    if (result.cleaned_files.length > 0) {
                        resultDiv.innerHTML += '<div class="alert alert-warning"><strong>清理的文件:</strong><br>';
                        result.cleaned_files.forEach(file => {
                            resultDiv.innerHTML += '课程: ' + file.course + ', 原名: ' + file.original_name + '<br>';
                        });
                        resultDiv.innerHTML += '</div>';
                    }
                    
                    showAlert(result.message, 'success');
                    DataManager.afterOperation('delete');
                    loadSongs();
                    loadCourses();
                } else {
                    resultDiv.innerHTML = '<div class="alert alert-error">更新失败: ' + result.error + '</div>';
                    showAlert('更新失败: ' + result.error, 'error');
                }
            } catch (error) {
                const resultDiv = document.getElementById('update-map-result');
                resultDiv.innerHTML = '<div class="alert alert-error">更新失败: ' + error.message + '</div>';
                showAlert('更新失败: ' + error.message, 'error');
            }
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
                    const courseFiles = result.restored.filter(f => f.type === 'course');
                    const songFiles = result.restored.filter(f => f.type === 'song');
                    
                    resultDiv.innerHTML = \`
                        <div class="alert alert-success">
                            <strong>\${result.message}</strong><br>
                            还原文件夹: \${result.music_folder}<br>
                            课程文件: \${courseFiles.length} 个<br>
                            歌曲文件: \${songFiles.length} 个<br>
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
        // 页面加载完成后初始化
        document.addEventListener('DOMContentLoaded', () => {
            loadOverview();
            
            // 定期更新缓存状态指示器和自动刷新
            setInterval(async () => {
                DataManager.updateCacheIndicator();
                // 每30秒检查一次是否需要自动刷新
                if (Math.random() < 0.1) { // 10%概率检查，避免过于频繁
                    await DataManager.autoRefreshIfNeeded();
                }
            }, 5000);
        });
    </script>
</body>
</html>`;
}

// ------------------- 启动 -------------------
app.listen(PORT, () => {
    console.log(`Server running at http://localhost:${PORT}`);
});
