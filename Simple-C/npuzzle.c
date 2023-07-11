/*
N-Puzzle Game
by XUJINKAI
first edition 2012
remake 2022.4

Compile:
linux:   gcc npuzzle.c -o npuzzle
windows: cl npuzzle.c
*/

#if defined(_WIN32)
#define __WIN32__
#elif defined(__linux__)
#define __LINUX__
#endif

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_SIZE     10
#define SHUFFLE_STEP 10000

typedef char KEYPRESS;
#define KEYPRESS_UP    'u'
#define KEYPRESS_DOWN  'd'
#define KEYPRESS_LEFT  'l'
#define KEYPRESS_RIGHT 'r'

struct npuzzle
{
    int map[MAX_SIZE][MAX_SIZE];
    int size;
    int step;
    int blank_row;
    int blank_col;
};

void showLogo()
{
    printf("///////////////////////////////////////////////////////\n"
           "//                   拼数字游戏                      //\n"
           "//                 制作: XUJINKAI                    //\n"
           "///////////////////////////////////////////////////////\n"
           "//            移动数字，使方阵按顺序排列             //\n"
           "//                 可选难度为3~%d                    //\n"
           "//               输入0或按Ctrl+C退出                 //\n"
           "///////////////////////////////////////////////////////\n"
           "\n",
           MAX_SIZE);
}

int readKeyPress()
{
#if defined(__WIN32__)
    return getch();
#elif defined(__LINUX__)
#include <termios.h>
    struct termios stored_settings;
    struct termios new_settings;
    tcgetattr(0, &stored_settings);
    new_settings = stored_settings;
    new_settings.c_lflag &= (~ECHO);
    new_settings.c_lflag &= (~ICANON);
    new_settings.c_cc[VTIME] = 0;
    new_settings.c_cc[VMIN]  = 1;
    tcsetattr(0, TCSANOW, &new_settings);
    char a = getchar();
    tcsetattr(0, TCSANOW, &stored_settings);
    // printf("%c(%d)\n", a, a);
    return a;
#endif
}

#if defined(__WIN32__)
#include <Windows.h>
#endif
void moveCursor(int col, int row)
{
#if defined(__WIN32__)
    COORD pos;
    pos.X = col;
    pos.Y = row;
    SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), pos);
#elif defined(__LINUX__)
    printf("\033[%d;%dH", row, col);
#endif
}

void clearTerminal()
{
#if defined(__WIN32__)
    system("cls");
#elif defined(__LINUX__)
    printf("\033[2J");
#endif
    moveCursor(0, 0);
}

void moveNPuzzle(struct npuzzle *s, KEYPRESS press)
{
    int n = s->size;
    switch (press)
    {
        case KEYPRESS_UP:
            if (s->blank_row < n - 1)
            {
                s->map[s->blank_row][s->blank_col] = s->map[s->blank_row + 1][s->blank_col];
                s->blank_row += 1;
                s->step++;
            }
            break;
        case KEYPRESS_DOWN:
            if (s->blank_row > 0)
            {
                s->map[s->blank_row][s->blank_col] = s->map[s->blank_row - 1][s->blank_col];
                s->blank_row -= 1;
                s->step++;
            }
            break;
        case KEYPRESS_LEFT:
            if (s->blank_col < n - 1)
            {
                s->map[s->blank_row][s->blank_col] = s->map[s->blank_row][s->blank_col + 1];
                s->blank_col += 1;
                s->step++;
            }
            break;
        case KEYPRESS_RIGHT:
            if (s->blank_col > 0)
            {
                s->map[s->blank_row][s->blank_col] = s->map[s->blank_row][s->blank_col - 1];
                s->blank_col -= 1;
                s->step++;
            }
            break;

        default:
            return;
    }
    s->map[s->blank_row][s->blank_col] = n * n;
}

bool npuzzleDone(struct npuzzle *s)
{
    int n = s->size;
    for (int i = 0; i < n; i++)
    {
        for (int j = 0; j < n; j++)
        {
            if (i * n + j + 1 != s->map[i][j])
            {
                return false;
            }
        }
    }
    return true;
}

void initNPuzzleState(struct npuzzle *s, int n)
{
    memset(s, 0, sizeof(struct npuzzle));
    s->size      = n;
    s->blank_row = n - 1;
    s->blank_col = n - 1;

    int i, j;
    for (i = 0; i < n; i++)
    {
        for (j = 0; j < n; j++)
        {
            s->map[i][j] = i * n + j + 1;
        }
    }

    KEYPRESS lastPress = 0;
    for (i = 0; i <= SHUFFLE_STEP; i++)
    {
        switch (rand() % 4)
        {
            case 0:
                if (lastPress != KEYPRESS_DOWN)
                {
                    moveNPuzzle(s, KEYPRESS_UP);
                    lastPress = KEYPRESS_UP;
                }
                break;
            case 1:
                if (lastPress != KEYPRESS_UP)
                {
                    moveNPuzzle(s, KEYPRESS_DOWN);
                    lastPress = KEYPRESS_DOWN;
                }
                break;
            case 2:
                if (lastPress != KEYPRESS_RIGHT)
                {
                    moveNPuzzle(s, KEYPRESS_LEFT);
                    lastPress = KEYPRESS_LEFT;
                }
                break;
            case 3:
                if (lastPress != KEYPRESS_LEFT)
                {
                    moveNPuzzle(s, KEYPRESS_RIGHT);
                    lastPress = KEYPRESS_RIGHT;
                }
                break;
        }
    }

    // moveNPuzzle will increase step, so reset it
    s->step = 0;
}

void displayNPuzzleUI(struct npuzzle *s)
{
    moveCursor(0, 0);
    printf("拼数字游戏\n"
           "\n"
           "移动: a s d w (或1 2 3 5)\n"
           "返回: 0\n"
           "重开: r\n"
           "\n"
           "  已走%d步\n"
           "\n",
           s->step);
    for (int row = 0; row < s->size; row++)
    {
        for (int col = 0; col < s->size; col++)
        {
            if (row != s->blank_row || col != s->blank_col)
            {
                printf("%4d", s->map[row][col]);
            }
            else
            {
                printf("    ");
            }
        }
        printf("\n\n");
    }
}

void startNPuzzleGame(int n)
{
    struct npuzzle s;
    initNPuzzleState(&s, n);

    clearTerminal();
    displayNPuzzleUI(&s);

    do
    {
        KEYPRESS press = 0;
        do
        {
            int key = readKeyPress();
            switch (key)
            {
                case 'w':
                case '5':
                    press = KEYPRESS_UP;
                    break;
                case 's':
                case '2':
                    press = KEYPRESS_DOWN;
                    break;
                case 'a':
                case '1':
                    press = KEYPRESS_LEFT;
                    break;
                case 'd':
                case '3':
                    press = KEYPRESS_RIGHT;
                    break;
                case 'r':
                    startNPuzzleGame(n);
                    return;
                case '0':
                    return;
                case 3: // Ctrl + C (for Windows)
                    exit(0);
                    return;
            }
        } while (press == 0);

        moveNPuzzle(&s, press);
        displayNPuzzleUI(&s);
    } while (!npuzzleDone(&s));

    printf("\n"
           "恭喜完成!!!\n"
           "\n"
           "按r再来一次, 按0返回");
    while (1)
    {
        switch (readKeyPress())
        {
            case 'r':
                startNPuzzleGame(n);
                return;
            case '0':
                return;
        }
    }
}

int main()
{
    srand(time(0));
    while (1)
    {
        clearTerminal();
        showLogo();
        int n = 0;
        do
        {
            printf("输入阶数(3~%d): ", MAX_SIZE);
            scanf("%d", &n);
            if (n == 0)
            {
                return 0;
            }
        } while (n < 3 || n > MAX_SIZE);
        startNPuzzleGame(n);
    }
    return 0;
}
